#!/bin/bash
set -euo pipefail

DATA_ROOT="${1:-}"
PYTHON="${2:-}"
case "$DATA_ROOT" in
  /*/com.kenyu.VoicePointer.IntegratedPreview) ;;
  *) exit 64 ;;
esac
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_ROOT="$(cd "$DIR/../Seed/payload" && pwd)"
case "$PYTHON" in
  "$ASSET_ROOT"/.cache/venvs/voicenative-beta/bin/python) ;;
  *) exit 64 ;;
esac
if [ ! -x "$PYTHON" ] || [ ! -f "$DATA_ROOT/Models/library.json" ]; then
  exit 64
fi
mkdir -p "$DATA_ROOT/.cache/tmp"
export VOICENATIVE_DATA_ROOT="$DATA_ROOT"
export VOICENATIVE_ASSET_ROOT="$ASSET_ROOT"
export TMPDIR="$DATA_ROOT/.cache/tmp/"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/sandbox-exec -D "DATA_ROOT=$DATA_ROOT" -f "$DIR/local-worker.sb" \
  "$PYTHON" "$DIR/punctuation_worker.py"
