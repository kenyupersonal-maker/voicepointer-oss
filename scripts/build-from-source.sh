#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(/usr/bin/python3 scripts/version_registry.py --default)"
/bin/bash scripts/build-maintenance04.sh
/bin/bash scripts/build-integrated-ali-worker.sh "$root/.cache/maintenance04-build/AliRealtimeWorker"
VOICEPOINTER_SOURCE_BUILD=1 /usr/bin/python3 -c 'import sys; sys.path.insert(0, "scripts"); from voicepointer_bundle import assemble; assemble(sys.argv[1])' "$version"
app="$root/.cache/maintenance04-build/VoicePointer-$version-candidate.app"
worker="$app/Contents/Resources/Backend/AliRealtimeWorker"
/usr/bin/codesign --force --sign - "$worker"
/usr/bin/python3 scripts/voicepointer_bundle.py --refresh-manifest "$app"
/usr/bin/codesign --force --sign - --entitlements IntegratedPreview/Maintenance04/Resources/Packaging/entitlements.plist "$app"
/usr/bin/codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
