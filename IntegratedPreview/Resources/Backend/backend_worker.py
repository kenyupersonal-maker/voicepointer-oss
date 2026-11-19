"""Bounded offline JSONL worker. No audio files or network calls."""
from __future__ import annotations
import argparse, base64, binascii, hashlib, importlib.util, importlib.metadata, json, math, os, re, resource, sys, time
from collections import OrderedDict
from pathlib import Path
ROOT = Path(os.environ['VOICENATIVE_ASSET_ROOT']).resolve()
DATA_ROOT = Path(os.environ['VOICENATIVE_DATA_ROOT']).resolve()
CATALOG = json.loads(Path(__file__).with_name('catalog.json').read_text())
MAX_PCM, MAX_B64, MAX_LINE = 1920000, 2560000, 2600000
ID_RE = re.compile(r'^[A-Za-z0-9._:-]{1,128}$')
MAX_STAGE_EVENTS = 256

KNOWN_ERROR_CODES = frozenset({
    'CONTEXT_INVALID', 'CONTEXT_CHANGED', 'CONTEXT_UNSUPPORTED',
    'INVALID_PCM16_BASE64_LENGTH', 'INVALID_PCM16_BASE64', 'INVALID_PCM16_BYTE_LENGTH',
    'INVALID_OPERATION', 'INVALID_SESSION_ID', 'INVALID_REVISION', 'INVALID_FINAL',
    'SESSION_FINAL_ALREADY_RECEIVED', 'REVISION_NOT_INCREASING',
    'PCM_PREFIX_SHRINK', 'PCM_PREFIX_REWRITTEN', 'ACTIVE_SESSION_EXISTS',
    'AUDIO_TOO_LONG', 'INVALID_STAGE_EVENT_OFFSET', 'STAGE_EVENTS_LIMIT_EXCEEDED',
    'INVALID_STAGE_EVENT', 'INVALID_STAGE_EVENT_RANGE', 'INVALID_STAGE_EVENT_SEGMENT',
    'INVALID_BACKEND_TEXT', 'INVALID_BACKEND_RAW_TRANSCRIPT',
    'INVALID_BACKEND_MOSS_SEGMENTS', 'PROFILE_UNSUPPORTED', 'RESPONSE_TOO_LARGE',
})

def safe_error_code(error):
    """Return error code only if it is an exact known code; never echo arbitrary text."""
    try:
        text = str(error)
    except Exception:
        return 'BACKEND_FAILURE'
    return text if text in KNOWN_ERROR_CODES else 'BACKEND_FAILURE'

def runtime_versions(backend=None):
    versions = {'python': sys.version.split()[0]}
    for name in ('numpy', 'torch', 'transformers', 'safetensors', 'mlx', 'mlx-metal', 'mlx-qwen3-asr', 'sherpa-onnx', 'sherpa-onnx-core'):
        try: versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError: versions[name] = 'unavailable'
    device = getattr(backend, 'device', None)
    if device is not None:
        versions['device'] = str(getattr(device, 'type', device))
    model = getattr(backend, 'model', None)
    dtype = getattr(model, 'dtype', None)
    if dtype is not None:
        versions['dtype'] = str(dtype).removeprefix('torch.')
    return versions

def _usage():
    r = resource.getrusage(resource.RUSAGE_SELF)
    rss = int(r.ru_maxrss)
    if sys.platform != 'darwin':
        rss *= 1024
    return {'cpu_ms': (r.ru_utime + r.ru_stime) * 1000, 'peak_rss_bytes': rss}

def _resource_usage(before):
    after = _usage()
    return {'request_cpu_ms': round(max(0.0, after['cpu_ms'] - before['cpu_ms']), 3),
            'process_cpu_ms': round(after['cpu_ms'], 3),
            'peak_rss_bytes': after['peak_rss_bytes']}

def strict_b64(v):
    if not isinstance(v, str) or len(v) > MAX_B64:
        raise ValueError('INVALID_PCM16_BASE64_LENGTH')
    try:
        raw = base64.b64decode(v.encode('ascii'), validate=True)
    except (UnicodeEncodeError, binascii.Error) as e:
        raise ValueError('INVALID_PCM16_BASE64') from e
    if len(raw) > MAX_PCM or len(raw) % 2:
        raise ValueError('INVALID_PCM16_BYTE_LENGTH')
    return raw

def _context_text(o):
    value = o.get('context', '')
    if not isinstance(value, str):
        raise ValueError('CONTEXT_INVALID')
    try:
        encoded = value.encode('utf-8')
    except UnicodeEncodeError as e:
        raise ValueError('CONTEXT_INVALID') from e
    if len(encoded) > 1024:
        raise ValueError('CONTEXT_INVALID')
    if value.strip() != value:
        raise ValueError('CONTEXT_INVALID')
    for ch in value:
        code = ord(ch)
        if (code < 32 or code == 127) and ch != '\n' and ch != '\t':
            raise ValueError('CONTEXT_INVALID')
    return value

def validate(o, sessions):
    if not isinstance(o, dict) or o.get('op') != 'infer':
        raise ValueError('INVALID_OPERATION')
    sid, rev = o.get('session_id'), o.get('revision')
    if not isinstance(sid, str) or not ID_RE.fullmatch(sid):
        raise ValueError('INVALID_SESSION_ID')
    if isinstance(rev, bool) or not isinstance(rev, int) or not 0 <= rev <= 1000000:
        raise ValueError('INVALID_REVISION')
    raw, final = strict_b64(o.get('pcm16_b64')), o.get('final', False)
    if not isinstance(final, bool):
        raise ValueError('INVALID_FINAL')
    context = _context_text(o)
    p = sessions.get(sid)
    if p:
        if p['final']: raise ValueError('SESSION_FINAL_ALREADY_RECEIVED')
        if rev <= p['revision']: raise ValueError('REVISION_NOT_INCREASING')
        if len(raw) < p['bytes']: raise ValueError('PCM_PREFIX_SHRINK')
        if hashlib.sha256(raw[:p['bytes']]).hexdigest() != p['prefix_sha256']:
            raise ValueError('PCM_PREFIX_REWRITTEN')
        if p.get('context_sha256', hashlib.sha256(b'').hexdigest()) != hashlib.sha256(context.encode('utf-8')).hexdigest():
            raise ValueError('CONTEXT_CHANGED')
    return sid, rev, raw, final

def process(o, sessions, backend, max_seconds=60):
    sid, rev, raw, final = validate(o, sessions)
    context = _context_text(o)
    p = sessions.get(sid)
    if any(k != sid and not v['final'] for k, v in sessions.items()):
        raise ValueError('ACTIVE_SESSION_EXISTS')
    if len(raw) > max_seconds * 32000: raise ValueError('AUDIO_TOO_LONG')
    context_sha256 = hashlib.sha256(context.encode('utf-8')).hexdigest()
    setter = None
    if context:
        setter = getattr(backend, 'set_context', None)
        if not callable(setter):
            raise ValueError('CONTEXT_UNSUPPORTED')
    import numpy as np
    started = time.monotonic()
    usage_before = _usage()
    stage_events, last_offset = [], -1.0
    def observe(kind, text, audio_start_sample, audio_end_sample, segment_index):
        nonlocal last_offset
        now = max(last_offset, max(0.0, (time.monotonic() - started) * 1000))
        if not math.isfinite(now): raise ValueError('INVALID_STAGE_EVENT_OFFSET')
        if len(stage_events) >= MAX_STAGE_EVENTS: raise ValueError('STAGE_EVENTS_LIMIT_EXCEEDED')
        if not isinstance(kind, str) or not isinstance(audio_start_sample, int) or not isinstance(audio_end_sample, int):
            raise ValueError('INVALID_STAGE_EVENT')
        if audio_start_sample < 0 or audio_end_sample < audio_start_sample:
            raise ValueError('INVALID_STAGE_EVENT_RANGE')
        if segment_index is not None and (not isinstance(segment_index, int) or segment_index < 0):
            raise ValueError('INVALID_STAGE_EVENT_SEGMENT')
        stage_events.append({'kind': kind, 'offset_ms': round(now, 3),
                             'text': text if text is None or isinstance(text, str) else str(text),
                             'audio_start_sample': audio_start_sample,
                             'audio_end_sample': audio_end_sample,
                             'segment_index': segment_index})
        last_offset = now
    if p is None:
        backend.reset()
        if setter is None:
            setter = getattr(backend, 'set_context', None)
        if callable(setter): setter(context)
    previous_observer = getattr(backend, 'observer', None)
    setattr(backend, 'observer', observe)
    metadata = {'revision': rev, 'bytes': len(raw),
                'prefix_sha256': hashlib.sha256(raw).hexdigest(), 'final': final,
                'context_sha256': context_sha256}
    try:
        observe('inference_start', None, 0, len(raw) // 2, None)
        samples = np.frombuffer(raw[p['bytes'] if p else 0:], dtype='<i2').astype(np.float32) / 32768
        out = backend.consume(samples, final)
        result = out if isinstance(out, dict) else {'text': out}
        if not isinstance(result.get('text'), str): raise ValueError('INVALID_BACKEND_TEXT')
        if 'raw_transcript' in result and not isinstance(result['raw_transcript'], str):
            raise ValueError('INVALID_BACKEND_RAW_TRANSCRIPT')
        if 'moss_segments' in result and not isinstance(result['moss_segments'], list):
            raise ValueError('INVALID_BACKEND_MOSS_SEGMENTS')
        observe('inference_end', result['text'], 0, len(raw) // 2, None)
    except Exception as exc:
        metadata['final'], metadata['failed'] = True, True
        sessions[sid] = metadata
        while len(sessions) > 64: sessions.popitem(last=False)
        exc.stage_events = stage_events
        exc.resource_usage = _resource_usage(usage_before)
        raise
    finally:
        if hasattr(backend, 'observer'): backend.observer = previous_observer
    sessions[sid] = metadata
    sessions.move_to_end(sid)
    while len(sessions) > 64: sessions.popitem(last=False)
    from backends import confidence_fields
    confidence = confidence_fields(result) if result['text'].strip() else {}
    return {'type': 'result', 'session_id': sid, 'revision': rev, 'text': result['text'],
            'final': final, 'compute_ms': round((time.monotonic()-started)*1000, 3),
            'stage_events': stage_events, 'resource_usage': _resource_usage(usage_before),
            **{k: result[k] for k in ('committed_text','draft_text','segment_count','segments','processed_samples',
                                      'raw_transcript','moss_segments') if k in result}, **confidence}

def capabilities():
    for p in CATALOG:
        if p['id'] in ('qwen06-rolling', 'qwen17-rolling', 'qwen06-incremental'):
            from model_library import model_directory
            try: model_directory(DATA_ROOT, p['id']); missing = []
            except (ValueError, KeyError, OSError): missing = ['MODEL_LIBRARY_MISSING']
        else: missing = [x for x in p['required_files'] if not (ROOT/x).is_file()]
        dependencies = p.get('required_modules', [])
        absent = [m for m in dependencies if importlib.util.find_spec(m) is None]
        status = 'unsupported' if p.get('host') == 'native' else ('missing_assets' if missing else ('missing_runtime' if absent else 'ready'))
        yield {'type':'capability', 'profile_id':p['id'], 'status':status,
               'missing':missing, 'missing_runtime':absent,
               'reason': '由原生宿主检查系统语音资源' if p.get('host')=='native' else '',
               'runtime_tested':False}

def make_backend(pid, lang):
    from backends import OfflineSenseVoice, SherpaOnline, RollingQwen, TwoPass
    d = ROOT/'asr-lab/models'
    sense = d/'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17'
    zipdir = d/'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20'
    if pid == 'sensevoice': return OfflineSenseVoice(sense, lang)
    if pid == 'zipformer': return SherpaOnline(zipdir)
    if pid == 'zipformer-small': return SherpaOnline(d/'zipformer-small-bilingual-2023-02-16-e238275')
    if pid == 'paraformer': return SherpaOnline(d/'sherpa-onnx-streaming-paraformer-bilingual-zh-en', 'paraformer')
    if pid in ('qwen06-rolling','qwen17-rolling','qwen06-incremental'):
        from model_library import model_directory
        return RollingQwen(model_directory(DATA_ROOT, pid),
                           lang, incremental=pid.endswith('incremental'))
    if pid in ('zipformer-sensevoice','zipformer-qwen17'):
        from model_library import model_directory
        corrector = OfflineSenseVoice(sense,lang) if pid.endswith('sensevoice') else RollingQwen(model_directory(DATA_ROOT, 'qwen17-rolling'),lang)
        return TwoPass(SherpaOnline(zipdir), corrector)
    if pid == 'nemotron':
        from nemotron import Nemotron
        return Nemotron(d/'nemotron-3.5-asr-streaming-0.6b-1c8deae/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf',lang)
    if pid == 'moss-transcribe-diarize':
        from moss import OfflineMoss
        return OfflineMoss(d/'MOSS-Transcribe-Diarize-704aa4a', lang)
    raise ValueError('PROFILE_UNSUPPORTED')

def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument('--profile', choices=[p['id'] for p in CATALOG])
    parser.add_argument('--language',choices=('auto','zh','en','yue'),default='auto')
    parser.add_argument('--capabilities',action='store_true')
    args=parser.parse_args(argv)
    # Preserve protocol fd; all third-party Python/C stdout goes to stderr.
    wire=os.fdopen(os.dup(1),'wb',buffering=0)
    sys.stdout.flush()
    os.dup2(2,1)
    def reply(value):
        data=(json.dumps(value,ensure_ascii=False,separators=(',',':'))+'\n').encode()
        if len(data)>MAX_LINE: raise ValueError('RESPONSE_TOO_LARGE')
        wire.write(data)
    if args.capabilities:
        for capability in capabilities(): reply(capability)
        return 0
    if not args.profile: return 2
    profile=next(p for p in CATALOG if p['id']==args.profile)
    if args.language not in profile['languages']:
        reply({'type':'error','error':'LANGUAGE_UNSUPPORTED'}); return 2
    os.environ['HF_HUB_OFFLINE']='1'
    os.environ['HF_HOME']=str(DATA_ROOT/'.cache/hf-cache')
    os.environ['HF_MODULES_CACHE']=str(DATA_ROOT/'.cache/hf-modules')
    os.environ['TOKENIZERS_PARALLELISM']='false'
    backend=None
    try:
        capability=next(p for p in capabilities() if p['profile_id']==args.profile)
        if capability['status']!='ready':
            reply({'type':'error','error':'PROFILE_UNAVAILABLE','capability':capability}); return 2
        started=time.monotonic()
        backend=make_backend(args.profile,args.language)
        load_ms=(time.monotonic()-started)*1000
        import numpy as np
        started=time.monotonic()
        warmup = getattr(backend, 'warmup', None)
        if callable(warmup): warmup()
        else: backend.consume(np.zeros(24000,dtype=np.float32),True)
        backend.reset()
        warm_ms=(time.monotonic()-started)*1000
        reply({'type':'ready','profile_id':args.profile,'worker_pid':os.getpid(),
               'load_ms':round(load_ms,3),'warmup_ms':round(warm_ms,3),'max_seconds':profile['max_seconds'],
               'runtime_versions':runtime_versions(backend)})
        sessions=OrderedDict()
        while True:
            line=sys.stdin.buffer.readline(MAX_LINE+1)
            if not line: break
            if len(line)>MAX_LINE or not line.endswith(b'\n'):
                reply({'type':'error','error':'REQUEST_LINE_TOO_LARGE'}); break
            obj=None
            try:
                obj=json.loads(line)
                if isinstance(obj,dict) and obj.get('op')=='shutdown':
                    reply({'type':'bye'}); break
                result=process(obj,sessions,backend,profile['max_seconds'])
                result['profile_id']=args.profile
                reply(result)
            except Exception as e:
                err={'type':'error','error':safe_error_code(e),'profile_id':args.profile}
                if hasattr(e, 'stage_events'):
                    err['stage_events'] = e.stage_events
                for attr in ('raw_transcript', 'moss_segments'):
                    if hasattr(e, attr): err[attr] = getattr(e, attr)
                if hasattr(e, 'resource_usage'):
                    err['resource_usage'] = e.resource_usage
                if isinstance(obj,dict):
                    if isinstance(obj.get('session_id'),str): err['session_id']=obj['session_id'][:128]
                    if type(obj.get('revision')) is int: err['revision']=obj['revision']
                reply(err)
    except Exception:
        reply({'type':'error','error':'WORKER_START_FAILED','profile_id':args.profile})
        return 2
    finally:
        if backend is not None: backend.close()
        wire.close()
    return 0

if __name__=='__main__':
    raise SystemExit(main())
