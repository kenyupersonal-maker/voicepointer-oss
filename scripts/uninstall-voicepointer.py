#!/usr/bin/env python3
"""T12 exact own-path uninstaller. Default is read-only; two explicit intents are required.

All removals are renames to Trash, including app data (no recursive deletion).
The fixed installed helper unregisters only SMAppService.mainApp without launching UI/capture.
Synthetic tests supply a separate home under this repository's .cache, never override HOME.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

from app_data_safety import confined, move_to_trash

spec = importlib.util.spec_from_file_location('migration', Path(__file__).with_name('migrate-model-library.py'))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)
BUNDLE_ID = migration.BUNDLE_ID
PROTECTED = {'keep-0.5.50', 'integrated-trial-04.app'}

def targets(home, synthetic=False):
    home = Path(home).absolute()
    if synthetic:
        cache = Path(__file__).resolve().parents[1] / '.cache'
        confined(home, [cache])
        if home == Path.home(): raise ValueError('REAL_HOME_FORBIDDEN')
    elif home != Path.home(): raise ValueError('HOME_MISMATCH')
    return {
        'app': (home / 'Applications/VoicePointer.app') if synthetic else Path('/Applications/VoicePointer.app'),
        'data': home / ('Library/Application Support/' + BUNDLE_ID),
        'preferences': home / ('Library/Preferences/' + BUNDLE_ID + '.plist'),
        'cache': home / ('Library/Caches/' + BUNDLE_ID),
        'login_item': home / ('Library/LaunchAgents/' + BUNDLE_ID + '.plist'),
    }

def preflight(path):
    confined(path, [path], allow_root=True)
    if any(name in path.parts for name in PROTECTED): raise ValueError('PROTECTED_PATH')
    if not path.exists(): return 0
    if path.is_file(): return path.stat().st_size
    if not path.is_dir(): raise ValueError('SPECIAL_FILE')
    total = 0
    for child in path.iterdir(): total += preflight(child)
    return total

def unregister(app, login_item, *, runner=subprocess.run, monotonic=time.monotonic, pause=time.sleep):
    if app.exists():
        # Public bundle identity only; no provider preferences or credentials.
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != BUNDLE_ID: raise ValueError('APP_IDENTITY')
        if tuple(map(int, info.get('CFBundleShortVersionString', '').split('.'))) < (0, 5, 52):
            raise ValueError('UNINSTALL_HELPER_VERSION')
        helper = confined(app / 'Contents/MacOS/VoicePointerPreview', [app])
        deadline = monotonic() + 5
        while True:
            completed = runner([str(helper), '--unregister-login-item-for-uninstall', '--confirmed-data-removal'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if completed.returncode == 0: break
            if completed.returncode != 65: raise subprocess.CalledProcessError(completed.returncode, 'own_uninstall_helper')
            if monotonic() >= deadline: raise ValueError('APP_STILL_RUNNING')
            pause(0.05) # Wait only; the fixed helper checks exact identity/path and never quits or kills.
    if login_item.exists():
        # Legacy job: the exact plist is the only launchctl operand, never a wildcard/other label.
        state = runner(['/bin/launchctl', 'print', 'gui/' + str(os.getuid()) + '/' + BUNDLE_ID],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if state.returncode == 0:
            runner(['/bin/launchctl', 'bootout', 'gui/' + str(os.getuid()), str(login_item)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def uninstall(home, *, requested=False, confirmed=False, synthetic=False, stop_login=None):
    paths = targets(home, synthetic)
    sizes = {key: preflight(path) for key, path in paths.items()}
    result = dict(event='uninstall', status='dry_run', targets=sum(p.exists() for p in paths.values()), bytes=sum(sizes.values()))
    if not requested or not confirmed: return result
    trash = Path(home) / '.Trash'
    confined(trash, [Path(home)])
    if paths['app'].exists():
        info = plistlib.loads((paths['app'] / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != BUNDLE_ID: raise ValueError('APP_IDENTITY')
    # The fixed helper waits for a live exact installed app to exit; no quit/kill is sent to any process.
    # Check before the opaque snapshot and again immediately before Trash; a failed fence preserves active targets.
    (stop_login or unregister)(paths['app'], paths['login_item'])
    backup = Path(home) / 'Library/Application Support/VoicePointer-Migration-Backups' / ('data-removal-' + uuid.uuid4().hex)
    migration.opaque_backup(paths['data'], paths['preferences'], backup)
    (stop_login or unregister)(paths['app'], paths['login_item'])
    for path in paths.values():
        if path.exists(): move_to_trash(path, [path], trash, allow_root=True)
    result['status'] = 'trashed'
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--confirmed', action='store_true')
    parser.add_argument('--synthetic-home')
    args = parser.parse_args()
    try:
        # Synthetic executions are available only to the injected test API; CLI cannot launch a fixture helper.
        if args.synthetic_home and (args.apply or args.confirmed): raise ValueError('FIXTURE_APPLY_REQUIRES_TEST_API')
        result = uninstall(Path(args.synthetic_home) if args.synthetic_home else Path.home(),
                           requested=args.apply, confirmed=args.confirmed, synthetic=bool(args.synthetic_home))
        print(','.join(str(key) + '=' + str(value) for key, value in result.items()))
        return 0
    except (OSError, ValueError, TypeError, subprocess.SubprocessError, plistlib.InvalidFileException):
        print('event=uninstall,status=failed'); return 1

if __name__ == '__main__': raise SystemExit(main())
