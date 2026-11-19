#!/usr/bin/env python3
"""Groq cloud transcription worker. Stdio JSON-line protocol, stdlib only.

No global mutable state: every run is self-contained via locals/closures.
No network, auth, or filesystem access at import time.
"""

import base64
import binascii
import io
import json
import math
import re
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.request
import wave

URL = "https://api.groq.com/openai/v1/audio/transcriptions"
ROUTES = {"groq-v3", "groq-turbo"}
LANGS = {"zh", "en", "auto"}
MODELS = {"groq-v3": "whisper-large-v3", "groq-turbo": "whisper-large-v3-turbo"}
MAX_CONFIG = 8192
MAX_CMD_LINE = 14 * 1024 * 1024
MAX_WAV = 10 * 1024 * 1024
MAX_RESP = 1024 * 1024
MAX_BODY = 10 * 1024 * 1024 + 65536
UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


class SafeError(Exception):
    def __init__(self, code, retry_after_seconds=None):
        if code == "http_429" and type(retry_after_seconds) is int \
                and 0 <= retry_after_seconds <= 86400:
            self.retry_after_seconds = retry_after_seconds
        else:
            self.retry_after_seconds = None
        super().__init__(code)
        self.code = code


def _pairs(pairs):
    keys = set()
    for k, _v in pairs:
        if not isinstance(k, str) or k in keys:
            raise ValueError("duplicate or non-string key")
        keys.add(k)
    return dict(pairs)


def _reject_constant(_name):
    raise ValueError("non-finite constant")


def _jsonparse(data):
    """Strict JSON: reject duplicate keys and NaN/Infinity constants."""
    return json.loads(data, object_pairs_hook=_pairs, parse_constant=_reject_constant)


def _map_http(status):
    if status == 401:
        return "http_401"
    if status == 403:
        return "http_403"
    if status == 413:
        return "http_413"
    if status == 429:
        return "http_429"
    if isinstance(status, int) and 500 <= status <= 599:
        return "http_5xx"
    return "request_failed"


def _parse_retry_after(value):
    if not isinstance(value, str):
        return None
    s = value.strip()
    if not s or len(s) > 32:
        return None
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)?", s):
        return None
    try:
        n = math.ceil(float(s))
    except Exception:
        return None
    if type(n) is int and 0 <= n <= 86400:
        return n
    return None


def _http_failure(status, response):
    code = _map_http(status)
    retry = None
    if code == "http_429":
        try:
            retry = _parse_retry_after(response.headers.get("Retry-After"))
        except Exception:
            retry = None
    elif status == 400:
        try:
            body = response.read(8193)
            if body is not None and len(body) <= 8192:
                obj = _jsonparse(body.decode("utf-8"))
                if isinstance(obj, dict):
                    err = obj.get("error")
                    if isinstance(err, dict) and err.get("code") \
                            == "blocked_api_access":
                        code = "http_spend_limit"
        except Exception:
            pass
    return SafeError(code, retry)


def _check_wav(raw):
    if len(raw) < 12 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise SafeError("audio_invalid")
    if int.from_bytes(raw[4:8], "little") != len(raw) - 8:
        raise SafeError("audio_invalid")
    try:
        w = wave.open(io.BytesIO(raw))
        if (w.getnchannels() != 1 or w.getsampwidth() != 2
                or w.getframerate() != 16000 or w.getcomptype() != "NONE"
                or not 160 <= w.getnframes() <= 4800000
                or len(w.readframes(w.getnframes())) != w.getnframes() * 2):
            raise SafeError("audio_invalid")
        w.close()
    except SafeError:
        raise
    except Exception:
        raise SafeError("audio_invalid")
    # Manual chunk walk: duplicate fmt/data, truncated chunks, strict PCM fmt.
    pos = 12
    seen = set()
    fmt_body = None
    data_len = -1
    while pos + 8 <= len(raw):
        cid = raw[pos:pos + 4]
        size = int.from_bytes(raw[pos + 4:pos + 8], "little")
        body = pos + 8
        if body + size > len(raw):
            raise SafeError("audio_invalid")
        if cid in (b"fmt ", b"data"):
            if cid in seen:
                raise SafeError("audio_invalid")
            seen.add(cid)
            if cid == b"fmt ":
                fmt_body = raw[body:body + size]
            else:
                data_len = size
        pos = body + size + (size & 1)
    if pos != len(raw) or fmt_body is None or data_len < 0 or len(fmt_body) < 16:
        raise SafeError("audio_invalid")
    if int.from_bytes(fmt_body[0:2], "little") != 1:
        raise SafeError("audio_invalid")  # PCM only
    if int.from_bytes(fmt_body[2:4], "little") != 1:
        raise SafeError("audio_invalid")  # channels
    if int.from_bytes(fmt_body[4:8], "little") != 16000:
        raise SafeError("audio_invalid")  # rate
    if int.from_bytes(fmt_body[8:12], "little") != 32000:
        raise SafeError("audio_invalid")  # byte rate
    if int.from_bytes(fmt_body[12:14], "little") != 2:
        raise SafeError("audio_invalid")  # block align
    if int.from_bytes(fmt_body[14:16], "little") != 16:
        raise SafeError("audio_invalid")  # bit depth
    # Groq documents a 0.01-second minimum input file.
    if not 160 <= data_len // 2 <= 4800000 or data_len % 2 != 0:
        raise SafeError("audio_invalid")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _default_opener():
    handler = urllib.request.HTTPSHandler(context=ssl.create_default_context())
    return urllib.request.build_opener(handler, _NoRedirect())


def _multipart(fields, wav):
    boundary = secrets.token_hex(16)
    bnd = boundary.encode("ascii")
    parts = []
    for name, value in fields.items():
        parts.append(
            b"--" + bnd + b"\r\nContent-Disposition: form-data; name=\""
            + name.encode("ascii") + b"\"\r\n\r\n"
            + value.encode("utf-8") + b"\r\n")
    parts.append(
        b"--" + bnd
        + b"\r\nContent-Disposition: form-data; name=\"file\"; "
        + b"filename=\"record.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        + wav + b"\r\n")
    parts.append(b"--" + bnd + b"--\r\n")
    body = b"".join(parts)
    if len(body) > MAX_BODY:
        raise SafeError("audio_invalid")
    return body, "multipart/form-data; boundary=" + boundary


def run(binary_input, text_output, opener=None, clock=time.monotonic):
    sid = None
    seq = 0
    last_ms = 0
    origin = None

    def now_ms():
        nonlocal last_ms, origin
        try:
            t = float(clock())
            if math.isfinite(t) and t >= 0:
                if origin is None:
                    origin = t
                elapsed = (t - origin) * 1000
                if math.isfinite(elapsed) and elapsed >= last_ms:
                    last_ms = int(elapsed)
        except Exception:
            pass
        return last_ms

    def emit(payload):
        payload["session_id"] = sid
        payload["sequence"] = seq
        payload["host_ms"] = now_ms()
        try:
            text_output.write(json.dumps(payload, allow_nan=False) + "\n")
            text_output.flush()
            return True
        except Exception:
            return False

    try:
        now_ms()
        line = binary_input.readline(MAX_CONFIG + 1)
        if not line:
            return 0  # EOF before config: quiet exit
        if len(line) > MAX_CONFIG or not line.endswith(b"\n"):
            raise SafeError("config_invalid")
        try:
            cfg = _jsonparse(line.decode("utf-8"))
        except Exception:
            raise SafeError("config_invalid")
        if not isinstance(cfg, dict):
            raise SafeError("config_invalid")
        if set(cfg) != {"op", "session_id", "route", "language", "key"}:
            raise SafeError("config_invalid")
        if cfg["op"] != "configure":
            raise SafeError("config_invalid")
        sid_val = cfg["session_id"]
        if not isinstance(sid_val, str) or not UUID_RE.fullmatch(sid_val.lower()):
            raise SafeError("config_invalid")
        route = cfg["route"]
        if not isinstance(route, str) or route not in ROUTES:
            raise SafeError("config_invalid")
        language = cfg["language"]
        if not isinstance(language, str) or language not in LANGS:
            raise SafeError("config_invalid")
        key = cfg["key"]
        if (not isinstance(key, str) or not 16 <= len(key) <= 4096
                or any(not 33 <= ord(c) <= 126 for c in key)):
            raise SafeError("config_invalid")
        cfg.pop("key")
        sid = sid_val
        if not emit({"type": "ready"}):
            return 1
        seq = 1

        cmd_line = binary_input.readline(MAX_CMD_LINE + 1)
        if not cmd_line:
            return 0  # EOF after config: quiet exit
        if len(cmd_line) > MAX_CMD_LINE or not cmd_line.endswith(b"\n"):
            raise SafeError("command_invalid")
        try:
            cmd = _jsonparse(cmd_line.decode("utf-8"))
        except Exception:
            raise SafeError("command_invalid")
        if not isinstance(cmd, dict):
            raise SafeError("command_invalid")
        op = cmd.get("op")
        if op == "cancel":
            if set(cmd) != {"op", "session_id"}:
                raise SafeError("command_invalid")
            csid = cmd["session_id"]
            if not isinstance(csid, str) or csid.lower() != sid.lower():
                raise SafeError("command_invalid")
            if not emit({"type": "stopped"}):
                return 1
            return 0
        if op == "validate":
            if set(cmd) != {"op", "session_id"}:
                raise SafeError("command_invalid")
            vsid = cmd["session_id"]
            if not isinstance(vsid, str) or not UUID_RE.fullmatch(vsid.lower()) \
                    or vsid.lower() != sid.lower():
                raise SafeError("command_invalid")
            if opener is None:
                opener = _default_opener()
            vurl = "https://api.groq.com/openai/v1/models/" + MODELS[route]
            vreq = urllib.request.Request(vurl, method="GET")
            vreq.add_header("Authorization", "Bearer " + key)
            vreq.add_header("Accept", "application/json")
            vreq.add_header(
                "User-Agent", "VoiceNative/0.1 (macOS; speech transcription)")
            key = None  # drop local reference; no claim of zeroing
            t0 = now_ms()
            try:
                vresp = opener.open(vreq, timeout=12)
            except urllib.error.HTTPError as exc:
                failure = _http_failure(exc.code, exc)
                try:
                    exc.close()
                except Exception:
                    pass
                raise failure
            except Exception:
                raise SafeError("request_failed")
            try:
                vstatus = None
                try:
                    vstatus = vresp.status
                except Exception:
                    try:
                        vstatus = vresp.getcode()
                    except Exception:
                        vstatus = None
                if vstatus != 200:
                    raise _http_failure(vstatus, vresp)
                try:
                    vdata = vresp.read(65537)
                except Exception:
                    raise SafeError("request_failed")
            finally:
                try:
                    vresp.close()
                except Exception:
                    pass
            request_ms = now_ms() - t0
            if len(vdata) > 65536:
                raise SafeError("response_invalid")
            try:
                vobj = _jsonparse(vdata.decode("utf-8"))
            except Exception:
                raise SafeError("response_invalid")
            if not isinstance(vobj, dict):
                raise SafeError("response_invalid")
            if vobj.get("id") != MODELS[route] \
                    or vobj.get("object") != "model":
                raise SafeError("response_invalid")
            if "active" in vobj and vobj.get("active") is not True:
                raise SafeError("response_invalid")
            if not emit({"type": "validated", "mode": "model_access_only",
                         "request_ms": request_ms}):
                return 1
            return 0
        if op != "transcribe":
            raise SafeError("command_invalid")
        cmd_keys = set(cmd)
        if cmd_keys == {"op", "session_id", "wav_base64"}:
            prompt = None
        elif cmd_keys == {"op", "session_id", "wav_base64", "prompt"}:
            # Prompt context (R21 C3G2): fully validated before any HTTP
            # attempt; every failure is command_invalid with zero requests.
            prompt = cmd["prompt"]
            if not isinstance(prompt, str):
                raise SafeError("command_invalid")
            if not prompt.strip():
                raise SafeError("command_invalid")
            if "\x7f" in prompt or any(
                    ord(c) < 0x20 and c not in ("\n", "\t") for c in prompt):
                raise SafeError("command_invalid")
            try:
                if len(prompt.encode("utf-8")) > 208:
                    raise SafeError("command_invalid")
            except UnicodeEncodeError:
                raise SafeError("command_invalid")
        else:
            raise SafeError("command_invalid")
        csid = cmd["session_id"]
        if not isinstance(csid, str) or csid.lower() != sid.lower():
            raise SafeError("command_invalid")
        b64 = cmd["wav_base64"]
        if not isinstance(b64, str):
            raise SafeError("audio_invalid")
        try:
            raw = base64.b64decode(b64, validate=True)
        except (binascii.Error, ValueError):
            raise SafeError("audio_invalid")
        if len(raw) > MAX_WAV:
            raise SafeError("audio_invalid")
        _check_wav(raw)

        if opener is None:
            opener = _default_opener()
        fields = {
            "model": MODELS[route],
            "response_format": "json",
            "temperature": "0",
        }
        if language != "auto":
            fields["language"] = language
        if prompt is not None:
            fields["prompt"] = prompt
        body, ctype = _multipart(fields, raw)
        req = urllib.request.Request(URL, data=body, method="POST")
        req.add_header("Content-Type", ctype)
        req.add_header("Authorization", "Bearer " + key)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", "VoiceNative/0.1 (macOS; speech transcription)")
        key = None  # drop local reference; no claim of zeroing
        t0 = now_ms()
        try:
            resp = opener.open(req, timeout=30)
        except urllib.error.HTTPError as exc:
            failure = _http_failure(exc.code, exc)
            try:
                exc.close()
            except Exception:
                pass
            raise failure
        except Exception:
            raise SafeError("request_failed")
        try:
            status = None
            try:
                status = resp.status
            except Exception:
                try:
                    status = resp.getcode()
                except Exception:
                    status = None
            if status != 200:
                raise _http_failure(status, resp)
            try:
                data = resp.read(MAX_RESP + 1)
            except Exception:
                raise SafeError("request_failed")
        finally:
            try:
                resp.close()
            except Exception:
                pass
        request_ms = now_ms() - t0
        if len(data) > MAX_RESP:
            raise SafeError("response_invalid")
        try:
            obj = _jsonparse(data.decode("utf-8"))
        except Exception:
            raise SafeError("response_invalid")
        if not isinstance(obj, dict):
            raise SafeError("response_invalid")
        text = obj.get("text")
        if (not isinstance(text, str) or len(text) > 50000
                or len(text.encode("utf-8")) > MAX_RESP):
            raise SafeError("response_invalid")
        if not emit({"type": "final", "text": text,
                     "mode": "file_after_stop", "request_ms": request_ms}):
            return 1
        return 0
    except SafeError as exc:
        payload = {"type": "failed", "error_code": exc.code}
        if exc.retry_after_seconds is not None:
            payload["retry_after_seconds"] = exc.retry_after_seconds
        emit(payload)
        return 1
    except Exception:
        emit({"type": "failed", "error_code": "request_failed"})
        return 1


if __name__ == "__main__":
    try:
        _code = run(sys.stdin.buffer, sys.stdout)
    except BaseException:
        _code = 1
    sys.exit(_code)
