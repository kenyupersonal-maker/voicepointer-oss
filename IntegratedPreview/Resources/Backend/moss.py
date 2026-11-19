"""Offline MOSS-Transcribe-Diarize adapter.

The worker owns the model process and feeds this adapter only the new PCM
suffix of a cumulative request.  MOSS is an offline route: inference happens
once on the final request and the model's original timestamp/speaker text is
kept alongside the plain transcript.
"""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path
from typing import Any

import numpy as np
import os


ROOT = Path(os.environ['VOICENATIVE_ASSET_ROOT']).resolve()
VENDOR_PARSER = ROOT / "asr-lab/vendor/MOSS-Transcribe-Diarize/moss_transcribe_diarize/transcript_parser.py"
DEFAULT_PROMPT = (
    "请将音频转写为文本，每一段需以起始时间戳和说话人编号"
    "（[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，"
    "并在段末标注结束时间戳，以清晰标明该段语音范围。"
)
MAX_NEW_TOKENS = 2048
_parse_transcript = None


class BackendError(RuntimeError):
    pass


class MossOutputError(BackendError):
    """A model output that must not be reported as a successful transcript."""

    def __init__(self, code: str, raw_transcript: str, segments: list[dict[str, Any]] | None = None):
        super().__init__(code)
        self.raw_transcript = raw_transcript
        self.moss_segments = segments or []


def _official_parser():
    """Load only the upstream parser module, without installing the web app."""
    global _parse_transcript
    if _parse_transcript is not None:
        return _parse_transcript
    if not VENDOR_PARSER.is_file():
        raise BackendError("MOSS_PARSER_MISSING")
    name = "_voicenative_moss_transcript_parser"
    spec = importlib.util.spec_from_file_location(name, VENDOR_PARSER)
    if spec is None or spec.loader is None:
        raise BackendError("MOSS_PARSER_LOAD_FAILED")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    _parse_transcript = module
    return _parse_transcript


def parse_moss_transcript(raw_transcript: str) -> list[dict[str, Any]]:
    """Parse official ``[start][Sxx]text[end]`` output without rewriting it."""
    if not isinstance(raw_transcript, str):
        raise MossOutputError("MOSS_OUTPUT_PARSE_FAILED", str(raw_transcript), [])
    try:
        parser_module = _official_parser()
        parser = parser_module.TranscriptStreamParser()
        parsed = parser.feed(raw_transcript)
        # The upstream parser intentionally ignores an unfinished tail when
        # close() resets its state.  Reject that tail instead of accepting a
        # partial transcript as completed.
        if parser._state not in (parser._SEEK_START, parser._AFTER_END):
            raise ValueError("UNPARSED_TRANSCRIPT_TAIL")
        parsed.extend(parser.close())
        if raw_transcript.strip() and not raw_transcript.lstrip().startswith("["):
            raise ValueError("UNPARSED_TRANSCRIPT_PREFIX")
        # The permissive upstream parser can also skip malformed prefixes or
        # gaps between otherwise valid segments. Account for the full raw
        # string so that a partially parsed transcript never looks complete.
        segment_pattern = r"\[\d+(?:\.\d+)?\]\s*\[S\d+\].*?\[\d+(?:\.\d+)?\]"
        cursor, matched = 0, 0
        for match in re.finditer(segment_pattern, raw_transcript, re.DOTALL):
            if raw_transcript[cursor:match.start()].strip():
                raise ValueError("UNPARSED_TRANSCRIPT_CONTENT")
            cursor, matched = match.end(), matched + 1
        if raw_transcript[cursor:].strip() or matched != len(parsed):
            raise ValueError("UNPARSED_TRANSCRIPT_CONTENT")
    except MossOutputError:
        raise
    except Exception as exc:
        raise MossOutputError("MOSS_OUTPUT_PARSE_FAILED:" + str(exc)[:400], raw_transcript, []) from exc
    segments: list[dict[str, Any]] = []
    try:
        for segment in parsed:
            start, end = float(segment.start), float(segment.end)
            speaker, text = str(segment.speaker), str(segment.text)
            if not np.isfinite(start) or not np.isfinite(end) or start < 0 or end < start:
                raise ValueError("INVALID_SEGMENT_RANGE")
            if not speaker or not speaker.startswith("S"):
                raise ValueError("INVALID_SEGMENT_SPEAKER")
            segments.append({"start": start, "end": end, "speaker": speaker, "text": text})
    except Exception as exc:
        raise MossOutputError("MOSS_OUTPUT_PARSE_FAILED:" + str(exc)[:400], raw_transcript, segments) from exc
    if not segments:
        raise MossOutputError("MOSS_OUTPUT_PARSE_FAILED:NO_SEGMENTS", raw_transcript, [])
    return segments


class OfflineMoss:
    """One local MOSS model, resettable between worker sessions."""

    def __init__(self, model_dir: str | Path, language: str = "auto"):
        import torch
        from transformers import AutoModelForCausalLM, AutoProcessor

        self.model_dir = Path(model_dir)
        self.language = language
        self.torch = torch
        backends = getattr(torch, "backends", None)
        mps = getattr(backends, "mps", None)
        self.device = torch.device("mps" if mps is not None and mps.is_available() else "cpu")
        self.model = AutoModelForCausalLM.from_pretrained(
            str(self.model_dir),
            local_files_only=True,
            trust_remote_code=True,
            dtype=torch.float32,
            attn_implementation="sdpa",
        ).to(self.device).eval()
        self.processor = AutoProcessor.from_pretrained(
            str(self.model_dir),
            local_files_only=True,
            trust_remote_code=True,
        )
        self.reset()

    def reset(self):
        self.seen = 0
        self.closed = False
        self.text = ""
        self.raw_transcript = ""
        self.moss_segments: list[dict[str, Any]] = []
        self.raw = np.empty(0, dtype=np.float32)

    def warmup(self):
        """Run a short real generation warmup, ignoring its parse result."""
        self.raw = np.zeros(24_000, dtype=np.float32)
        try:
            self._generate(self.raw, max_new_tokens=32)
        finally:
            self.reset()

    def _result(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "raw_transcript": self.raw_transcript,
            "moss_segments": self.moss_segments,
        }

    def _generate(self, audio: np.ndarray, *, max_new_tokens: int):
        messages = [{
            "role": "user",
            "content": [
                {"type": "audio", "audio": audio},
                {"type": "text", "text": DEFAULT_PROMPT},
            ],
        }]
        prompt = self.processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        inputs = self.processor(text=prompt, audio=[audio], return_tensors="pt")
        if hasattr(inputs, "to"):
            inputs = inputs.to(self.device)
        else:
            inputs = {key: value.to(self.device) if hasattr(value, "to") else value for key, value in inputs.items()}
        with self.torch.inference_mode():
            output = self.model.generate(**inputs, do_sample=False, max_new_tokens=max_new_tokens)
        if self.device.type == "mps" and hasattr(self.torch, "mps") and hasattr(self.torch.mps, "synchronize"):
            self.torch.mps.synchronize()
        sequences = getattr(output, "sequences", output)
        if not hasattr(sequences, "shape") or len(sequences.shape) != 2:
            raise BackendError("MOSS_INVALID_GENERATION")
        prompt_length = int(inputs["input_ids"].shape[-1])
        if int(sequences.shape[-1]) < prompt_length:
            raise BackendError("MOSS_INVALID_GENERATION_LENGTH")
        generated = sequences[0][prompt_length:]
        generated_count = int(generated.shape[-1])
        tokenizer = getattr(self.processor, "tokenizer", self.processor)
        raw_transcript = tokenizer.decode(generated, skip_special_tokens=True)
        return raw_transcript, generated_count, generated, tokenizer

    def _infer(self) -> dict[str, Any]:
        raw_transcript, generated_count, generated, tokenizer = self._generate(
            self.raw, max_new_tokens=MAX_NEW_TOKENS
        )
        try:
            moss_segments = parse_moss_transcript(raw_transcript)
        except MossOutputError as exc:
            if self._hit_generation_cap(generated, generated_count, tokenizer):
                raise MossOutputError("MOSS_OUTPUT_TRUNCATED", raw_transcript, exc.moss_segments) from exc
            raise
        if self._hit_generation_cap(generated, generated_count, tokenizer):
            raise MossOutputError("MOSS_OUTPUT_TRUNCATED", raw_transcript, moss_segments)
        self.raw_transcript = raw_transcript
        self.moss_segments = moss_segments
        self.text = "".join(segment["text"] for segment in moss_segments)
        return self._result()

    def _hit_generation_cap(self, generated, generated_count: int, tokenizer) -> bool:
        if generated_count < MAX_NEW_TOKENS:
            return False
        eos = getattr(tokenizer, "eos_token_id", None)
        if eos is None:
            eos = getattr(getattr(self.model, "generation_config", None), "eos_token_id", None)
        eos_ids = {int(eos)} if isinstance(eos, int) else {int(value) for value in (eos or [])}
        if not eos_ids or not len(generated):
            return True
        return int(generated[-1]) not in eos_ids

    def consume(self, samples, final: bool = False):
        if self.closed:
            raise BackendError("SESSION_FINAL_ALREADY_RECEIVED")
        samples = np.asarray(samples, dtype=np.float32).reshape(-1)
        if len(samples):
            self.raw = np.concatenate((self.raw, samples))
        self.seen += len(samples)
        if not final:
            return {"text": self.text}
        if not len(self.raw):
            self.closed = True
            self.raw_transcript = ""
            self.moss_segments = []
            self.text = ""
            return self._result()
        try:
            result = self._infer()
        except MossOutputError as exc:
            self.raw_transcript = exc.raw_transcript
            self.moss_segments = exc.moss_segments
            self.text = ""
            self.closed = True
            raise
        except Exception:
            self.closed = True
            raise
        self.closed = True
        return result

    def close(self):
        self.closed = True
