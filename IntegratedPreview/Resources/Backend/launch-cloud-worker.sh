#!/bin/bash
# Bundled cloud launcher (I03U). Receives no arguments; rejects any.
# Keys are read only by the worker from stdin; never read, exported, or echoed here.

set -u

CLOUD_LAUNCH_FAIL_MSG='CLOUD_LAUNCH_INVALID'

fail() {
    printf '%s\n' "$CLOUD_LAUNCH_FAIL_MSG" >&2
    exit 64
}

# Reject any arguments.
[ "$#" -eq 0 ] || fail

# Resolve real absolute directory of this script.
SOURCE="${BASH_SOURCE[0]}" || fail
[ -n "$SOURCE" ] || fail
SCRIPT_DIR=$(dirname "$SOURCE") || fail
DIR=$(cd -P "$SCRIPT_DIR" 2>/dev/null && pwd -P) || fail
[ -n "$DIR" ] && [ -d "$DIR" ] || fail

# Resolve assets root physically (cd/pwd -P; may traverse bundled symlinked payloads).
ASSET_ROOT=$(cd -P "$DIR/../Seed/payload" 2>/dev/null && pwd -P) || fail
[ -n "$ASSET_ROOT" ] && [ -d "$ASSET_ROOT" ] || fail

PYTHON="$ASSET_ROOT/.cache/venvs/voicenative-beta/bin/python"
WORKER="$DIR/cloud_groq_worker.py"
PROFILE="$DIR/cloud-worker.sb"

# Validate required regular files. Note: -f/-x follow symlinks, so a legitimate
# bundled python exposed via symlink inside the asset tree is accepted.
[ -f "$PYTHON" ] && [ -x "$PYTHON" ] || fail
[ -f "$WORKER" ] || fail
[ -f "$PROFILE" ] || fail

# No mkdir, no file writes, no network calls in the launcher itself.
# Hand off to the sandboxed worker; keys arrive via stdin only.
exec /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    PYTHONNOUSERSITE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    /usr/bin/sandbox-exec \
        -D "BACKEND_ROOT=$DIR" \
        -D "ASSET_ROOT=$ASSET_ROOT" \
        -f "$PROFILE" \
        "$PYTHON" -I -B "$WORKER"

# exec failed.
fail
