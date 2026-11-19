"""严格按 nemo_speech/asr.h 的稳定 C ABI 绑定；不调用 CLI。"""
from __future__ import annotations
import ctypes, os
from pathlib import Path

ROOT = Path(os.environ['VOICENATIVE_ASSET_ROOT']).resolve()
RUNTIME = ROOT / ".cache/runtimes/nemo-speech-0.1.0/nemo-speech"
class BackendError(RuntimeError): pass

def _lib():
    lib = ctypes.CDLL(str(RUNTIME / "lib/libnemo_speech_asr_c.1.dylib"))
    return lib

class Nemotron:
    def __init__(self, model: Path, language="auto"):
        self.lib = _lib(); self.rec = ctypes.c_void_p(); self.stream = ctypes.c_void_p()
        class B(ctypes.Structure): _fields_=[("size",ctypes.c_size_t),("gpu",ctypes.c_int32)]
        class M(ctypes.Structure): _fields_=[("size",ctypes.c_size_t),("path",ctypes.c_char_p),("name",ctypes.c_char_p)]
        class S(ctypes.Structure): _fields_=[("size",ctypes.c_size_t),("chunk_size",ctypes.c_float),("ctc_left_padding",ctypes.c_float),("ctc_right_padding",ctypes.c_float),("rnnt_right_context",ctypes.c_int32)]
        class C(ctypes.Structure): _fields_=[("size",ctypes.c_size_t),("backend",ctypes.POINTER(B)),("model",ctypes.POINTER(M)),("streaming",ctypes.POINTER(S)),("decoder",ctypes.c_void_p),("vad",ctypes.c_void_p),("endpointing",ctypes.c_void_p),("postproc",ctypes.c_void_p),("diar",ctypes.c_void_p),("batching",ctypes.c_void_p)]
        class O(ctypes.Structure): _fields_=[("size",ctypes.c_size_t),("request_id",ctypes.c_char_p),("language_code",ctypes.c_char_p),("interim_results",ctypes.c_bool),("enable_word_time_offsets",ctypes.c_bool),("enable_automatic_punctuation",ctypes.c_bool),("verbatim_transcripts",ctypes.c_bool),("profanity_filter",ctypes.c_bool),("stop_history_eou_ms",ctypes.c_int32),("speech_contexts",ctypes.c_void_p),("speech_context_count",ctypes.c_size_t),("max_alternatives",ctypes.c_int32),("enable_speaker_diarization",ctypes.c_bool),("max_speaker_count",ctypes.c_int32)]
        self.O=O
        b=B(ctypes.sizeof(B),0); p=str(model).encode(); m=M(ctypes.sizeof(M),p,None); s=S(ctypes.sizeof(S),0.64,0.0,0.0,3); c=C(ctypes.sizeof(C),ctypes.pointer(b),ctypes.pointer(m),ctypes.pointer(s),None,None,None,None,None,None)
        for name in ('destroy','stream_close','result_destroy'):
            fn=getattr(self.lib,'nemo_speech_asr_'+name); fn.argtypes=[ctypes.c_void_p]; fn.restype=None
        self.lib.nemo_speech_asr_last_error.argtypes=[]
        self.lib.nemo_speech_asr_last_error.restype=ctypes.c_char_p
        self.lib.nemo_speech_asr_stream_finish.argtypes=[ctypes.c_void_p]
        self.lib.nemo_speech_asr_stream_finish.restype=ctypes.c_int
        self.lib.nemo_speech_asr_result_is_final.argtypes=[ctypes.c_void_p]
        self.lib.nemo_speech_asr_result_is_final.restype=ctypes.c_bool
        self.lib.nemo_speech_asr_recognition_options_default.argtypes=[]
        self.lib.nemo_speech_asr_recognition_options_default.restype=O
        self.lib.nemo_speech_asr_create.argtypes=[ctypes.POINTER(C),ctypes.POINTER(ctypes.c_void_p)]; self.lib.nemo_speech_asr_create.restype=ctypes.c_int
        if self.lib.nemo_speech_asr_create(ctypes.byref(c),ctypes.byref(self.rec)) != 0: raise BackendError(self._err())
        self.model_path=p; self.language={'auto':None,'zh':b'zh-CN','en':b'en-US','yue':b'yue-CN'}[language]
        self.reset()
    def _err(self):
        try: return (self.lib.nemo_speech_asr_last_error() or b"runtime").decode()
        except Exception: return "runtime"
    def start(self):
        opt=self.lib.nemo_speech_asr_recognition_options_default()
        opt.language_code=self.language; opt.interim_results=True; opt.enable_automatic_punctuation=True
        self.lib.nemo_speech_asr_streaming_recognize.argtypes=[ctypes.c_void_p,ctypes.POINTER(self.O),ctypes.POINTER(ctypes.c_void_p)]
        if self.lib.nemo_speech_asr_streaming_recognize(self.rec,ctypes.byref(opt),ctypes.byref(self.stream)) != 0: raise BackendError(self._err())
    def consume(self, samples, final=False):
        import array
        if self.closed: raise BackendError('SESSION_FINAL_ALREADY_RECEIVED')
        self.seen+=len(samples)
        if not self.seen and final: self.closed=True; return ''
        if not self.stream: self.start()
        arr=array.array("f",samples); push=self.lib.nemo_speech_asr_stream_push_f32; push.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_float),ctypes.c_size_t,ctypes.c_int32]
        if arr and push(self.stream,(ctypes.c_float*len(arr)).from_buffer(arr),len(arr),16000)!=0: raise BackendError(self._err())
        if final and self.lib.nemo_speech_asr_stream_finish(self.stream)!=0: raise BackendError(self._err())
        nxt=self.lib.nemo_speech_asr_stream_next; nxt.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)]; nxt.restype=ctypes.c_int
        saw_final=False
        while True:
            out=ctypes.c_void_p()
            if nxt(self.stream,ctypes.byref(out))!=0: raise BackendError(self._err())
            if not out: break
            fn=self.lib.nemo_speech_asr_result_transcript; fn.argtypes=[ctypes.c_void_p,ctypes.c_size_t]; fn.restype=ctypes.c_char_p
            try:
                self.text=(fn(out,0) or b'').decode(errors='replace')
                saw_final=saw_final or self.lib.nemo_speech_asr_result_is_final(out)
            finally: self.lib.nemo_speech_asr_result_destroy(out)
        if final:
            if not saw_final: raise BackendError('NEMOTRON_FINAL_MISSING')
            self.lib.nemo_speech_asr_stream_close(self.stream); self.stream=ctypes.c_void_p(); self.closed=True
        return self.text
    def reset(self):
        if self.stream: self.lib.nemo_speech_asr_stream_close(self.stream)
        self.stream=ctypes.c_void_p(); self.seen=0; self.text=''; self.closed=False
    def close(self):
        if self.stream: self.lib.nemo_speech_asr_stream_close(self.stream); self.stream=None
        if self.rec: self.lib.nemo_speech_asr_destroy(self.rec); self.rec=None
