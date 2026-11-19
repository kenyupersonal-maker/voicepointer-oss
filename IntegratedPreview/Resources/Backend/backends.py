"""Local recognizers. consume takes new samples; reset retains model weights."""
from pathlib import Path
import math
import numpy as np
RATE = 16000
CONFIDENCE_SOURCE = 'qwen_selected_token_min_probability_v1'

def confidence_fields(value):
    """Transport only validated numeric evidence and a fixed source; missing stays missing."""
    if not isinstance(value, dict):
        return {}
    probability, count = value.get('model_confidence'), value.get('model_confidence_token_count')
    if (type(probability) not in (int, float) or not 0 <= probability <= 1 or not math.isfinite(probability)
            or type(count) is not int or not 1 <= count <= 1000000
            or value.get('model_confidence_source') != CONFIDENCE_SOURCE):
        return {}
    return {'model_confidence': float(probability), 'model_confidence_source': CONFIDENCE_SOURCE,
            'model_confidence_token_count': count}

class BackendError(RuntimeError):
    pass

class FakeBackend:
    def __init__(self, fn=lambda x: ''):
        self.fn = fn
        self.reset()
    def reset(self):
        self.seen, self.closed, self.text = 0, False, ''
    def consume(self, samples, final=False):
        if self.closed:
            raise BackendError('SESSION_FINAL_ALREADY_RECEIVED')
        self.seen += len(samples)
        self.text = str(self.fn(np.asarray(samples, dtype=np.float32)))
        self.closed = final
        return self.text
    def close(self):
        self.closed = True

class OfflineSenseVoice(FakeBackend):
    def __init__(self, model_dir, language='auto'):
        import sherpa_onnx
        d = Path(model_dir)
        self.rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(d/'model.int8.onnx'), tokens=str(d/'tokens.txt'),
            num_threads=1, provider='cpu', language=language, use_itn=True)
        self.reset()
    def reset(self):
        super().reset()
        self.raw = np.empty(0, dtype=np.float32)
    def consume(self, samples, final=False):
        if self.closed:
            raise BackendError('SESSION_FINAL_ALREADY_RECEIVED')
        self.raw = np.concatenate((self.raw, samples))
        self.seen += len(samples)
        if final and len(self.raw):
            stream = self.rec.create_stream()
            stream.accept_waveform(RATE, self.raw)
            self.rec.decode_stream(stream)
            self.text = str(stream.result.text or '')
        self.closed = final
        return self.text

class SherpaOnline(FakeBackend):
    def __init__(self, model_dir, kind='zipformer'):
        import sherpa_onnx
        d = Path(model_dir)
        self.kind = kind
        if kind == 'paraformer':
            self.rec = sherpa_onnx.OnlineRecognizer.from_paraformer(
                tokens=str(d/'tokens.txt'), encoder=str(d/'encoder.int8.onnx'),
                decoder=str(d/'decoder.int8.onnx'), num_threads=1, provider='cpu')
        else:
            self.rec = sherpa_onnx.OnlineRecognizer.from_transducer(
                tokens=str(d/'tokens.txt'),
                encoder=str(d/'encoder-epoch-99-avg-1.int8.onnx'),
                decoder=str(d/'decoder-epoch-99-avg-1.onnx'),
                joiner=str(d/'joiner-epoch-99-avg-1.int8.onnx'),
                num_threads=1, sample_rate=RATE, feature_dim=80,
                decoding_method='greedy_search', modeling_unit='cjkchar+bpe',
                bpe_vocab=str(d/'bpe.vocab'))
        self.reset()
    def reset(self):
        super().reset()
        self.stream = self.rec.create_stream()
    def consume(self, samples, final=False):
        if self.closed:
            raise BackendError('SESSION_FINAL_ALREADY_RECEIVED')
        if len(samples):
            self.stream.accept_waveform(RATE, np.asarray(samples, dtype=np.float32))
        self.seen += len(samples)
        if final:
            self.stream.accept_waveform(RATE, np.zeros(10560, dtype=np.float32))
            if self.kind == 'paraformer':
                self.stream.set_option('is_final', '1')
            self.stream.input_finished()
        while self.rec.is_ready(self.stream):
            self.rec.decode_stream(self.stream)
        self.text = self.rec.get_result(self.stream)
        self.closed = final
        return self.text
    def close(self):
        self.stream = None
        super().close()

class RollingQwen(FakeBackend):
    def __init__(self, model_dir, language='auto', incremental=False):
        import mlx.core as mx
        from mlx_qwen3_asr import load_model, transcribe
        self.model, _ = load_model(str(model_dir), dtype=mx.float16)
        mx.eval(self.model.parameters())
        self.transcribe, self.model_dir = transcribe, str(model_dir)
        self.language = {'auto': None, 'zh': 'Chinese', 'en': 'English', 'yue': 'Cantonese'}[language]
        self.incremental = incremental
        self.reset()
    def reset(self):
        super().reset()
        self.raw = np.empty(0, dtype=np.float32)
        self.state = None
        self.context = ''
        self.confidence = {}
    def set_context(self, context):
        self.context = context
    def consume(self, samples, final=False):
        if self.closed:
            raise BackendError('SESSION_FINAL_ALREADY_RECEIVED')
        self.seen += len(samples)
        if self.incremental:
            # The incremental decoder bypasses _sample and does not expose matching stop metadata.
            self.confidence = {}
            from mlx_qwen3_asr.streaming import init_streaming, feed_audio, finish_streaming
            if self.state is None:
                self.state = init_streaming(model=self.model_dir, chunk_size_sec=0.5,
                    max_context_sec=30.0, sample_rate=RATE, finalization_mode='latency', language=self.language,
                    context=self.context)
            if len(samples):
                self.state = feed_audio(np.asarray(samples, dtype=np.float32), self.state, model=self.model)
            if final and self.seen:
                self.state = finish_streaming(self.state, model=self.model)
            self.text = str(self.state.text or '')
        else:
            self.raw = np.concatenate((self.raw, samples))
            if len(samples) or (final and len(self.raw)):
                from qwen_confidence import observe_qwen_generation
                with observe_qwen_generation() as observer:
                    result = self.transcribe(audio=self.raw, model=self.model,
                        max_new_tokens=512, language=self.language, context=self.context, verbose=False)
                self.text = str(result.text or '')
                self.confidence = confidence_fields(observer.payload(result)) if self.text.strip() else {}
        self.closed = final
        return {'text': self.text, **self.confidence}
    def close(self):
        self.context = ''
        self.state = None
        self.raw = np.empty(0, dtype=np.float32)
        self.confidence = {}
        super().close()

class TwoPass:
    """Eight-second non-overlapping segments; no word-boundary accuracy claim."""
    def __init__(self, online, corrector):
        self.online, self.corrector = online, corrector
        self.observer = None
        self.reset()
    def reset(self):
        self.online.reset()
        self.corrector.reset()
        self.raw = np.empty(0, dtype=np.float32)
        self.committed, self.ranges = [], []
        self.confidences = []
        self.seen, self.offset, self.closed, self.draft = 0, 0, False, ''
        # Observers belong to one host request and must not survive reset.
        self.observer = None
    def _observe(self, kind, text, start, end, segment_index):
        if self.observer is not None:
            self.observer(kind=kind, text=text, audio_start_sample=start,
                          audio_end_sample=end, segment_index=segment_index)
    @staticmethod
    def _event_text(value):
        return value if value is None or isinstance(value, str) else str(value)
    def _commit(self):
        start, end, segment = self.offset, self.offset + len(self.raw), len(self.committed)
        self._observe('draft_finalize_start', None, start, end, segment)
        draft_final = self.online.consume([], final=True)
        self._observe('draft_final', self._event_text(draft_final), start, end, segment)
        self._observe('correction_start', None, start, end, segment)
        self.corrector.reset()
        corrected_result = self.corrector.consume(self.raw, final=True)
        corrected = corrected_result.get('text', '') if isinstance(corrected_result, dict) else corrected_result
        self.confidences.append(confidence_fields(corrected_result))
        self._observe('correction_end', self._event_text(corrected), start, end, segment)
        self.committed.append(corrected)
        self.ranges.append([start, end])
        self._observe('segment_committed', self._event_text(corrected), start, end, segment)
        self.offset = end
        self.raw = np.empty(0, dtype=np.float32)
        self.draft = ''
        self.online.reset()
    def consume(self, samples, final=False):
        if self.closed:
            raise BackendError('SESSION_FINAL_ALREADY_RECEIVED')
        samples = np.asarray(samples, dtype=np.float32)
        self.seen += len(samples)
        pos = 0
        while pos < len(samples):
            count = min(8*RATE-len(self.raw), len(samples)-pos)
            chunk = samples[pos:pos+count]
            self.raw = np.concatenate((self.raw, chunk))
            self.draft = self.online.consume(chunk, final=False)
            self._observe('draft_result', self._event_text(self.draft), self.offset,
                          self.offset + len(self.raw), len(self.committed))
            pos += count
            if len(self.raw) == 8*RATE:
                self._commit()
        if final:
            if len(self.raw):
                self._commit()
            self.draft, self.closed = '', True
        committed = ' '.join(x.strip() for x in self.committed if x.strip())
        evidence = [score for text, score in zip(self.committed, self.confidences) if text.strip()]
        confidence = {}
        if not self.draft.strip() and evidence and all(evidence):
            total = sum(score['model_confidence_token_count'] for score in evidence)
            confidence = confidence_fields({'model_confidence': min(score['model_confidence'] for score in evidence),
                'model_confidence_source': CONFIDENCE_SOURCE, 'model_confidence_token_count': total})
        return {'text': ' '.join(x for x in (committed, self.draft.strip()) if x),
                'committed_text': committed, 'draft_text': self.draft,
                'segment_count': len(self.committed), 'segments': self.ranges,
                'processed_samples': self.seen, **confidence}
    def close(self):
        self.online.close()
        self.corrector.close()
        self.closed = True
