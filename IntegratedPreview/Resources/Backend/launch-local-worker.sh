#!/bin/bash
set -euo pipefail

DATA_ROOT="${1:-}"
PYTHON="${2:-}"
shift 2 || true

case "$DATA_ROOT" in
  /*/com.kenyu.VoicePointer.IntegratedPreview) ;;
  *) echo "invalid DATA_ROOT" >&2; exit 64 ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_ROOT="$(cd "$DIR/../Seed/payload" && pwd)"

case "$PYTHON" in
  "$ASSET_ROOT"/.cache/venvs/*/bin/python) ;;
  *) echo "invalid PYTHON" >&2; exit 64 ;;
esac

if [ ! -x "$PYTHON" ]; then
  echo "invalid PYTHON" >&2
  exit 64
fi

mkdir -p "$DATA_ROOT/.cache/tmp"
export VOICENATIVE_DATA_ROOT="$DATA_ROOT"
export VOICENATIVE_ASSET_ROOT="$ASSET_ROOT"
export TMPDIR="$DATA_ROOT/.cache/tmp/"
exec /usr/bin/sandbox-exec -D "DATA_ROOT=$DATA_ROOT" -f "$DIR/local-worker.sb" "$PYTHON" "$DIR/backend_worker.py" "$@"
