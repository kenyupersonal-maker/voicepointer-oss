"""Observe scores from the shipped mlx-qwen3-asr 0.4.0 decode, without replay.

Usage (the caller keeps the original transcribe function and arguments)::

    with observe_qwen_generation() as observer:
        result = transcribe(...)
    evidence = observer.payload(result)

Only the synchronous, non-speculative ``transcribe`` pipeline from the shipped
0.4.0 runtime is supported. Its module aliases are temporarily observed inside
one worker process; no installed library file is edited. One context must cover
exactly one transcription on the entering thread. Other versions, streaming,
speculation, nested/overlapping observations, or incomplete evidence yield {}.

The score is the minimum raw-logit softmax probability of every generated
non-EOS token, including any generated language header. It is an uncalibrated
model generation score, not a probability that the transcript is correct.
Reduction/synchronization adds work, but never calls a model or changes sampling.
No transcript, audio, logits, or token sequence is logged or persisted here.
"""

from __future__ import annotations

import importlib
import math
import threading


SOURCE = "qwen_selected_token_min_probability_v1"
_PATCH_LOCK = threading.Lock()


class _GenerationBlock:
    def __init__(self):
        self.valid = True
        self.eos_ids = ()
        self.samples = []
        self.confidence = None
        self.token_count = 0

    def configure(self, args, kwargs, generate_module):
        config = kwargs.get("config")
        if "config" not in kwargs and len(args) > 4:
            config = args[4]
        if config is None:
            config = generate_module.GenerationConfig()
        eos_ids = config.eos_token_ids
        if not isinstance(eos_ids, (list, tuple)) or not eos_ids:
            self.valid = False
            return
        if any(type(token) is not int or token < 0 for token in eos_ids):
            self.valid = False
            return
        if config.temperature != 0.0:
            self.valid = False
            return
        self.eos_ids = tuple(eos_ids)

    def sample(self, logits, token, temperature, mx):
        if not self.valid:
            return
        if type(token) is not int or temperature != 0.0:
            self.valid = False
            return
        shape = tuple(logits.shape)
        if not (1 <= len(shape) <= 3 and shape[-1] > 0):
            self.valid = False
            return
        if any(dimension != 1 for dimension in shape[:-1]):
            self.valid = False
            return
        if not 0 <= token < shape[-1]:
            self.valid = False
            return
        flat = logits.reshape(-1).astype(mx.float32)
        if not bool(mx.all(mx.isfinite(flat)).item()):
            self.valid = False
            return
        # Use unscaled model logits, never the degenerate greedy-choice measure.
        log_probability = float((flat[token] - mx.logsumexp(flat)).item())
        if not math.isfinite(log_probability) or log_probability > 0.0:
            self.valid = False
            return
        probability = math.exp(log_probability)
        if not math.isfinite(probability) or not 0.0 <= probability <= 1.0:
            self.valid = False
            return
        self.samples.append((token, probability))

    def finish(self, result, result_class):
        try:
            if not self.valid or not isinstance(result, result_class):
                self.valid = False
                return
            tokens = result.tokens
            if not isinstance(tokens, list) or not tokens:
                self.valid = False
                return
            if any(type(token) is not int or token < 0 for token in tokens):
                self.valid = False
                return
            if result.finish_reason != "eos" or result.truncated is not False:
                self.valid = False
                return
            if type(result.generated_tokens) is not int or result.generated_tokens != len(tokens):
                self.valid = False
                return
            if type(result.max_new_tokens) is not int or result.max_new_tokens <= len(tokens):
                self.valid = False
                return
            observed_tokens = [token for token, _ in self.samples]
            # 0.4.0 samples the EOS, then strips exactly that sentinel in its result.
            if len(observed_tokens) != len(tokens) + 1:
                self.valid = False
                return
            if observed_tokens[:-1] != tokens or observed_tokens[-1] not in self.eos_ids:
                self.valid = False
                return
            if any(token in self.eos_ids for token in tokens):
                self.valid = False
                return
            self.confidence = min(probability for _, probability in self.samples[:-1])
            self.token_count = len(tokens)
        finally:
            # Retain only a scalar/count after the existing generation returns.
            self.samples.clear()


class _QwenGenerationObservation:
    def __init__(self):
        self._invalid = False
        self._entered = False
        self._exited = False
        self._normal_exit = False
        self._owns_lock = False
        self._owner = None
        self._patches = []
        self._inside_pipeline = False
        self._pipeline_calls = 0
        self._split_calls = 0
        self._expected_blocks = None
        self._active_block = None
        self._blocks = []
        self._result = None
        self._transcription_class = None

    def _on_owner_thread(self):
        return threading.get_ident() == self._owner

    def __enter__(self):
        self._entered = True
        self._owner = threading.get_ident()
        self._owns_lock = _PATCH_LOCK.acquire(blocking=False)
        if not self._owns_lock:
            self._invalid = True
            return self
        try:
            package = importlib.import_module("mlx_qwen3_asr")
            generate_module = importlib.import_module("mlx_qwen3_asr.generate")
            transcribe_module = importlib.import_module("mlx_qwen3_asr.transcribe")
            mx = importlib.import_module("mlx.core")
            if getattr(package, "__version__", None) != "0.4.0":
                self._invalid = True
                return self
            original_generate = generate_module.generate_with_info
            original_sample = generate_module._sample
            original_pipeline = transcribe_module._transcribe_loaded_components
            original_split = transcribe_module.split_audio_into_chunks
            generation_class = generate_module.GenerationResult
            self._transcription_class = transcribe_module.TranscriptionResult
            if transcribe_module.generate is not original_generate:
                self._invalid = True
                return self
            if not all(callable(value) for value in (
                    original_generate, original_sample, original_pipeline, original_split)):
                self._invalid = True
                return self
            if not isinstance(generation_class, type) or not isinstance(self._transcription_class, type):
                self._invalid = True
                return self

            def sampled(logits, temperature):
                token = original_sample(logits, temperature)
                if self._on_owner_thread():
                    try:
                        if self._active_block is not None:
                            self._active_block.sample(logits, token, temperature, mx)
                        elif self._inside_pipeline:
                            # A decode bypassed the observed normal generator.
                            self._invalid = True
                    except Exception:
                        self._invalid = True
                        if self._active_block is not None:
                            self._active_block.valid = False
                return token

            def generated(*args, **kwargs):
                if not self._on_owner_thread():
                    return original_generate(*args, **kwargs)
                if not self._inside_pipeline or self._active_block is not None:
                    self._invalid = True
                    return original_generate(*args, **kwargs)
                block = _GenerationBlock()
                try:
                    block.configure(args, kwargs, generate_module)
                except Exception:
                    block.valid = False
                self._blocks.append(block)
                self._active_block = block
                try:
                    output = original_generate(*args, **kwargs)
                except BaseException:
                    self._invalid = True
                    raise
                finally:
                    self._active_block = None
                try:
                    block.finish(output, generation_class)
                except Exception:
                    block.valid = False
                return output

            def split(*args, **kwargs):
                chunks = original_split(*args, **kwargs)
                if self._on_owner_thread() and self._inside_pipeline:
                    try:
                        self._split_calls += 1
                        if not isinstance(chunks, (list, tuple)):
                            self._invalid = True
                        else:
                            self._expected_blocks = len(chunks)
                    except Exception:
                        self._invalid = True
                return chunks

            def pipeline(*args, **kwargs):
                if not self._on_owner_thread():
                    return original_pipeline(*args, **kwargs)
                self._pipeline_calls += 1
                previous_inside = self._inside_pipeline
                if previous_inside or self._pipeline_calls != 1 or kwargs.get("draft_model_obj") is not None:
                    self._invalid = True
                self._inside_pipeline = True
                try:
                    result = original_pipeline(*args, **kwargs)
                except BaseException:
                    self._invalid = True
                    raise
                finally:
                    self._inside_pipeline = previous_inside
                self._result = result
                return result

            for module, name, original, wrapper in (
                    (generate_module, "_sample", original_sample, sampled),
                    (transcribe_module, "generate", original_generate, generated),
                    (transcribe_module, "split_audio_into_chunks", original_split, split),
                    (transcribe_module, "_transcribe_loaded_components", original_pipeline, pipeline)):
                self._patches.append((module, name, original))
                setattr(module, name, wrapper)
        except Exception:
            self._invalid = True
            self._restore()
        return self

    def _restore(self):
        for module, name, original in reversed(self._patches):
            try:
                setattr(module, name, original)
            except Exception:
                self._invalid = True
        self._patches.clear()

    def __exit__(self, exc_type, exc_value, traceback):
        self._normal_exit = exc_type is None
        if not self._normal_exit:
            self._invalid = True
        try:
            self._restore()
        finally:
            self._exited = True
            if self._owns_lock:
                self._owns_lock = False
                _PATCH_LOCK.release()
        return False

    def payload(self, result):
        """Return complete same-call evidence, or {}. Never inspect result text."""
        try:
            if self._invalid or not self._exited or not self._normal_exit:
                return {}
            if self._pipeline_calls != 1 or self._split_calls != 1:
                return {}
            if result is not self._result or not isinstance(result, self._transcription_class):
                return {}
            if result.finish_reason != "eos" or result.truncated is not False:
                return {}
            if not self._expected_blocks or len(self._blocks) != self._expected_blocks:
                return {}
            if result.chunks is not None and len(result.chunks) != self._expected_blocks:
                return {}
            if any(not block.valid or block.confidence is None or block.token_count <= 0 for block in self._blocks):
                return {}
            confidence = min(block.confidence for block in self._blocks)
            count = sum(block.token_count for block in self._blocks)
            if not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
                return {}
            return {
                "model_confidence": confidence,
                "model_confidence_source": SOURCE,
                "model_confidence_token_count": count,
            }
        except Exception:
            return {}


def observe_qwen_generation():
    """Create a fail-closed, temporary observer for one existing transcription."""
    return _QwenGenerationObservation()
