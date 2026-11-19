"""Read-only provider models probe. Credentials only arrive on the input pipe.

The launcher fixes a single provider. No redirects, audio, filesystem writes,
raw response errors, user settings, or provider fallback exist in this worker.
"""
import json
import socket
import ssl
import sys
import urllib.error
import urllib.request
import uuid

PROVIDERS = {
    "groq": ("https://api.groq.com/openai/v1/models", ("whisper-large-v3-turbo", "whisper-large-v3")),
    "openai": ("https://api.openai.com/v1/models", ("gpt-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1")),
    "siliconflow": ("https://api.siliconflow.cn/v1/models", ("FunAudioLLM/SenseVoiceSmall", "TeleAI/TeleSpeechASR")),
}
MAX_INPUT = 8193
MAX_RESPONSE = 1_048_576
TIMEOUT = 8
ERROR_CODES = frozenset(("rejectedKey", "noAccess", "insufficientQuota", "rateLimited",
                        "serviceUnavailable", "network", "timeout", "unknown", "invalid"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("duplicate")
        result[name] = value
    return result


def parse_request(raw, provider):
    value = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != {"v", "type", "provider", "session_id", "key"}:
        raise ValueError("shape")
    if type(value["v"]) is not int or value["v"] != 1 or value["type"] != "models" or value["provider"] != provider:
        raise ValueError("identity")
    session = value["session_id"]
    if not isinstance(session, str) or str(uuid.UUID(session)).upper() != session.upper():
        raise ValueError("session")
    key = value["key"]
    if not isinstance(key, str) or not 16 <= len(key) <= 4096 or not all(33 <= ord(c) <= 126 for c in key):
        raise ValueError("key")
    return session, key


def parse_models(body, provider):
    value = json.loads(body, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or not isinstance(value.get("data"), list) or len(value["data"]) > 10000:
        raise ValueError("models")
    ids = {row["id"] for row in value["data"] if isinstance(row, dict) and isinstance(row.get("id"), str)}
    return [model for model in PROVIDERS[provider][1] if model in ids]


def http_failure(status, body, provider):
    if status == 401:
        return "rejectedKey"
    if status == 403:
        return "noAccess"
    if status == 429:
        if provider == "openai":
            try:
                error = json.loads(body).get("error", {})
                if isinstance(error, dict) and (error.get("code") == "insufficient_quota" or error.get("type") == "insufficient_quota"):
                    return "insufficientQuota"
            except (ValueError, AttributeError, TypeError):
                pass
        return "rateLimited"
    if 500 <= status <= 599:
        return "serviceUnavailable"
    return "unknown"


def probe(provider, key, opener=None):
    # Explicit ProxyHandler({}) avoids inherited environment/user proxy routing.
    # System TLS trust and the exact single provider URL are the only destinations.
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(PROVIDERS[provider][0], method="GET", headers={"Authorization": "Bearer " + key})
    try:
        with opener.open(request, timeout=TIMEOUT) as response:
            body = response.read(MAX_RESPONSE + 1)
            if response.status != 200 or len(body) > MAX_RESPONSE:
                return {"kind": "failed", "code": "unknown"}
            return {"kind": "models", "models": parse_models(body, provider)}
    except urllib.error.HTTPError as error:
        try:
            body = error.read(MAX_RESPONSE + 1)
            if len(body) > MAX_RESPONSE:
                body = b""
            return {"kind": "failed", "code": http_failure(error.code, body, provider)}
        finally:
            error.close()
    except (socket.timeout, TimeoutError):
        return {"kind": "failed", "code": "timeout"}
    except urllib.error.URLError as error:
        return {"kind": "failed", "code": "timeout" if isinstance(error.reason, (socket.timeout, TimeoutError)) else "network"}
    except (OSError, ssl.SSLError):
        return {"kind": "failed", "code": "network"}
    except (ValueError, TypeError, KeyError):
        return {"kind": "failed", "code": "unknown"}
    finally:
        # Drop immutable header copies immediately. Owned input bytes are zeroed in main.
        request.remove_header("Authorization")
        key = ""


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in PROVIDERS:
        return 64
    provider = sys.argv[1]
    raw = bytearray(sys.stdin.buffer.readline(MAX_INPUT + 1))
    session = None
    key = ""
    try:
        if not raw or len(raw) > MAX_INPUT or raw[-1] != 10:
            return 64
        session, key = parse_request(raw, provider)
        result = probe(provider, key)
        result.update({"v": 1, "provider": provider, "session_id": session})
        sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        return 0
    except (ValueError, UnicodeError, TypeError, KeyError):
        # Invalid input yields no content that could reflect a key or arbitrary identifier.
        return 64
    finally:
        for index in range(len(raw)):
            raw[index] = 0
        raw.clear()
        key = ""


if __name__ == "__main__":
    raise SystemExit(main())
