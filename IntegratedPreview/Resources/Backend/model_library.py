"""T11 external Models/library.json presence resolver. No network, mutation or ASR."""
import json
import re
from pathlib import Path

REQUIRED = {
    'qwen06-rolling': {'config.json', 'model.safetensors', 'preprocessor_config.json', 'tokenizer_config.json', 'vocab.json', 'merges.txt', 'chat_template.json'},
    'qwen17-rolling': {'config.json', 'model.safetensors', 'preprocessor_config.json', 'tokenizer_config.json', 'vocab.json', 'merges.txt', 'chat_template.json', 'quantization_config.json'},
    'punctuation': {'model.int8.onnx'},
}

def confined(root, relative):
    root = Path(root).absolute()
    path = Path(relative)
    if path.is_absolute() or not path.parts or any(p in ('.', '..') for p in path.parts):
        raise ValueError('MODEL_LIBRARY_PATH')
    result = root / path
    if not result.is_relative_to(root) or any(p.is_symlink() for p in [result, *result.parents]):
        raise ValueError('MODEL_LIBRARY_PATH')
    return result

def model_directory(data_root, identifier):
    if identifier == 'qwen06-incremental': identifier = 'qwen06-rolling'
    if identifier not in REQUIRED: raise ValueError('MODEL_LIBRARY_ID')
    root = Path(data_root).absolute() / 'Models'
    index = confined(root, 'library.json')
    if not index.is_file() or index.stat().st_size >= 2_000_000: raise ValueError('MODEL_LIBRARY_MISSING')
    value = json.loads(index.read_bytes())
    if value.get('schema_version') != 1 or not set(value['models']).issubset(REQUIRED): raise ValueError('MODEL_LIBRARY_SCHEMA')
    entry = value['models'][identifier]
    if not isinstance(entry.get('version'), str) or not entry['version'] or entry.get('source') not in ('download', 'migration'):
        raise ValueError('MODEL_LIBRARY_METADATA')
    if not entry['directory'].startswith('installed/'): raise ValueError('MODEL_LIBRARY_PATH')
    directory = confined(root, entry['directory'])
    files = entry['files']
    names = [f['name'] for f in files]
    if len(names) != len(set(names)) or not REQUIRED[identifier].issubset(names): raise ValueError('MODEL_LIBRARY_FILES')
    for file in files:
        if '/' in file['name'] or not re.fullmatch(r'[a-f0-9]{64}', file['sha256']): raise ValueError('MODEL_LIBRARY_FILES')
        path = confined(root, entry['directory'] + '/' + file['name'])
        if not isinstance(file['bytes'], int) or isinstance(file['bytes'], bool) or file['bytes'] <= 0 \
                or not path.is_file() or path.stat().st_size != file['bytes']: raise ValueError('MODEL_LIBRARY_MISSING')
    return directory
