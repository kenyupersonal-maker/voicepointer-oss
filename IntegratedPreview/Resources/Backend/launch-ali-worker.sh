#!/bin/bash
set -euo pipefail

# Launcher for the Ali realtime worker.
# Security properties enforced here:
#   - accepts no arguments (any argument is treated as tampering)
#   - resolves its own directory physically (symlinks followed via cd -P)
#   - validates launcher-referenced files are regular, non-symlink files
#   - launches the worker under sandbox-exec with a minimal environment
#   - the API key is never passed via argv, environment, files, or this script;
#     it is delivered only on the worker's stdin pipe by the host process.

if [ $# -eq 0 ]; then
    :
else
    printf '%s\n' 'ALI_LAUNCH_INVALID' >&2
    exit 64
fi

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

WORKER="$DIR/AliRealtimeWorker"
PROFILE="$DIR/ali-worker.sb"

for f in "$WORKER" "$PROFILE"; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then
        :
    else
        printf '%s\n' 'ALI_LAUNCH_INVALID' >&2
        exit 64
    fi
done

if [ -x "$WORKER" ]; then
    :
else
    printf '%s\n' 'ALI_LAUNCH_INVALID' >&2
    exit 64
fi

exec /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    /usr/bin/sandbox-exec \
    -D "BACKEND_ROOT=$DIR" \
    -f "$PROFILE" \
    "$WORKER"

