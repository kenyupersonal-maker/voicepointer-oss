"""Single-request local punctuation worker. No audio, credentials, or network."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

MAX_LINE = 150_000


def read_object():
    line = sys.stdin.buffer.readline(MAX_LINE + 1)
    if not line or len(line) > MAX_LINE or not line.endswith(b"\n"):
        raise ValueError("INVALID_REQUEST")
    try:
        value = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("INVALID_REQUEST") from exc
    if not isinstance(value, dict):
        raise ValueError("INVALID_REQUEST")
    return value


def reply(kind, **values):
    sys.stdout.write(json.dumps({"type": kind, **values}, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    if read_object() != {"op": "start", "version": 1}:
        raise ValueError("INVALID_START")
    from model_library import model_directory
    model = model_directory(os.environ["VOICENATIVE_DATA_ROOT"], "punctuation") / "model.int8.onnx"
    if not model.is_file() or model.is_symlink() or model.resolve(strict=True) != model:
        raise ValueError("MODEL_MISSING")

    import sherpa_onnx

    config = sherpa_onnx.OfflinePunctuationConfig(
        model=sherpa_onnx.OfflinePunctuationModelConfig(
            ct_transformer=str(model), num_threads=1, provider="cpu"
        )
    )
    engine = sherpa_onnx.OfflinePunctuation(config)
    reply("ready", version=1)

    request = read_object()
    text = request.get("text")
    if set(request) != {"op", "text"} or request.get("op") != "punctuate" or not isinstance(text, str):
        raise ValueError("INVALID_REQUEST")
    if not text or len(text.encode("utf-8")) > 100_000 or "\x00" in text:
        raise ValueError("INVALID_TEXT")
    candidate = engine.add_punctuation(text)
    if not isinstance(candidate, str) or len(candidate.encode("utf-8")) > 150_000:
        raise ValueError("INVALID_RESULT")
    reply("result", candidate=candidate)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never echo text, path, model exception, or arbitrary error details.
        reply("error", code="PUNCTUATION_UNAVAILABLE")
        raise SystemExit(1)
