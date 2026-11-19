#!/usr/bin/env python3
"""T11 copy-only model migration. Private data is copied opaquely, never parsed/logged."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sys

from app_data_safety import confined
_backend = Path(__file__).resolve().parent.parent / 'Backend'
if not _backend.is_dir():
    _backend = Path(__file__).resolve().parents[1] / 'IntegratedPreview/Resources/Backend'
sys.path.insert(0, str(_backend))
from model_library import model_directory, REQUIRED

BUNDLE_ID = 'com.kenyu.voicepointer.mac'
BACKUP_EXCLUDED = {'Models', 'ModelDownloads', '.cache', 'Logs', 'logs', 'runtime.log'}
AUDIO_EXTENSIONS = {'.wav', '.pcm', '.mp3', '.m4a', '.flac', '.aiff', '.caf', '.ogg'}

def atomic_json(path, value):
    path = Path(path)
    confined(path, [path.parent])
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name('.' + path.name + '.partial')
    confined(temporary, [path.parent])
    with temporary.open('wb') as stream:
        stream.write(json.dumps(value, sort_keys=True, separators=(',', ':')).encode())
        stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)

def opaque_backup(data_root, preferences, backup):
    data_root, preferences, backup = map(Path, (data_root, preferences, backup))
    if backup.name == 'keep-0.5.50' or 'keep-0.5.50' in backup.parts: raise ValueError('BACKUP_PRESERVED')
    confined(backup / 'backup-complete.json', [backup])
    if (backup / 'backup-complete.json').is_file(): return
    sources = []
    if data_root.is_dir():
        confined(data_root, [data_root], allow_root=True)
        for directory, folders, files in os.walk(data_root, followlinks=False):
            base = Path(directory)
            folders[:] = [name for name in folders if name not in BACKUP_EXCLUDED]
            if any((base / name).is_symlink() for name in folders): raise ValueError('BACKUP_SYMLINK')
            for name in files:
                source = base / name
                if name in BACKUP_EXCLUDED or source.suffix.lower() in AUDIO_EXTENSIONS: continue
                if source.is_symlink(): raise ValueError('BACKUP_SYMLINK')
                if source.is_file(): sources.append((source, Path('ApplicationSupport-' + BUNDLE_ID) / source.relative_to(data_root)))
    if preferences.exists():
        confined(preferences, [preferences.parent])
        if not preferences.is_file(): raise ValueError('PREFERENCES_NOT_REGULAR')
        sources.append((preferences, Path(BUNDLE_ID + '.plist')))
    total = sum(source.stat().st_size for source, _ in sources)
    if total >= 49_000_000: raise ValueError('BACKUP_TOO_LARGE')
    for source, relative in sources:
        destination = confined(backup / relative, [backup])
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copy2(source, destination)  # Opaque copy; no decoding or content logging.
    atomic_json(backup / 'backup-complete.json', {'schema_version': 1, 'private_data_parsed': False, 'files': len(sources), 'bytes': total})

def checksum(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while chunk := stream.read(1024 * 1024): digest.update(chunk)
    return digest.hexdigest()

def matches(path, file):
    return path.is_file() and not path.is_symlink() and path.stat().st_size == file['bytes'] and checksum(path) == file['sha256']

def migrate(source_app, data_root, preferences, backup, catalog, stop_after=None):
    source_app, data_root = Path(source_app).absolute(), Path(data_root).absolute()
    confined(source_app, [source_app], allow_root=True)
    info = plistlib.loads((source_app / 'Contents/Info.plist').read_bytes())  # Public bundle metadata only.
    if info.get('CFBundleIdentifier') != BUNDLE_ID or not re.fullmatch(r'0\.5\.5[0-9](?:\.[0-9]+)?', info.get('CFBundleShortVersionString', '')):
        raise ValueError('MIGRATION_SOURCE_VERSION')
    if catalog.get('schema_version') != 1 or {m['id'] for m in catalog['models']} != set(REQUIRED):
        raise ValueError('MIGRATION_CATALOG')
    opaque_backup(data_root, preferences, backup)  # Must finish before creating/publishing model changes.
    root = data_root / 'Models'
    index_path = confined(root / 'library.json', [root])
    index = json.loads(index_path.read_bytes()) if index_path.is_file() else {'schema_version': 1, 'models': {}}
    if index.get('schema_version') != 1 or not set(index['models']).issubset(REQUIRED): raise ValueError('MODEL_LIBRARY_SCHEMA')
    copied = registered = skipped = checkpoints = 0
    for model in catalog['models']:
        identifier = model['id']
        try:
            model_directory(data_root, identifier)
            skipped += 1; continue  # Existing installed model wins; migration never replaces an active model.
        except (OSError, ValueError, KeyError): pass
        prefix = model['prefix']
        if not prefix.startswith('asr-lab/models/') or '..' in Path(prefix).parts: raise ValueError('MIGRATION_MODEL_PATH')
        source_root = confined(source_app / 'Contents/Resources/Seed/payload' / prefix, [source_app])
        if not source_root.is_dir(): continue  # A genuinely absent group can be downloaded later; never invent readiness.
        files = model['files']
        names = [f['name'] for f in files]
        if len(names) != len(set(names)) or not REQUIRED[identifier].issubset(names): raise ValueError('MIGRATION_FILES')
        version_tag = hashlib.sha256(model['version'].encode()).hexdigest()[:12]
        relative = 'installed/migrated-' + identifier + '-' + version_tag
        destination = confined(root / relative, [root])
        stage = confined(root / '.migration' / (identifier + '-' + version_tag), [root])
        stage.mkdir(parents=True, exist_ok=True, mode=0o700)
        for file in files:
            if '/' in file['name'] or file['name'] in ('.', '..') or not re.fullmatch(r'[a-f0-9]{64}', file['sha256']): raise ValueError('MIGRATION_FILE_PATH')
            source = confined(source_root / file['name'], [source_app])
            if not matches(source, file): raise ValueError('MIGRATION_SOURCE_CHECKSUM')
            target = confined(stage / file['name'], [root])
            if not matches(target, file):
                temporary = confined(stage / ('.' + file['name'] + '.partial'), [root])
                shutil.copyfile(source, temporary)
                if not matches(temporary, file): raise ValueError('MIGRATION_COPY_CHECKSUM')
                os.replace(temporary, target); copied += 1
            checkpoints += 1
            if stop_after is not None and checkpoints >= stop_after: raise InterruptedError('MIGRATION_TEST_INTERRUPT')
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if destination.exists():
            # Only an already complete directory is reusable. A corrupt published directory is preserved for diagnosis.
            if not all(matches(confined(destination / f['name'], [root]), f) for f in files): raise ValueError('MIGRATION_DESTINATION_CORRUPT')
        else: os.rename(stage, destination)
        index['models'][identifier] = {'directory': relative, 'version': model['version'], 'source': 'migration', 'files': files}
        atomic_json(index_path, index)  # Each complete group is published independently; interrupted next groups remain closed.
        model_directory(data_root, identifier)
        registered += 1
    return {'schema_version': 1, 'copied': copied, 'registered': registered, 'skipped': skipped, 'source_untouched': True}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-app', required=True)
    parser.add_argument('--data-root', required=True)
    parser.add_argument('--preferences', required=True)
    parser.add_argument('--backup', required=True)
    parser.add_argument('--catalog', required=True)
    args = parser.parse_args()
    try:
        result = migrate(args.source_app, args.data_root, args.preferences, args.backup, json.loads(Path(args.catalog).read_bytes()))
    except (OSError, ValueError, KeyError, TypeError):
        print('event=model_migration,status=failed', file=sys.stderr); return 1
    print('event=model_migration,status=passed,schema=1,copied=' + str(result['copied']) + ',registered=' + str(result['registered']) + ',skipped=' + str(result['skipped']))
    return 0

if __name__ == '__main__': raise SystemExit(main())
