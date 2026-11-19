#!/bin/bash
set -eu
[ "$#" -eq 0 ] || exit 64
VP_MODELS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
VP_MODELS_ASSETS=$(cd -P "$VP_MODELS_DIR/../Seed/payload" && pwd -P)
VP_MODELS_PYTHON="$VP_MODELS_ASSETS/.cache/venvs/voicenative-beta/bin/python"
[ -f "$VP_MODELS_PYTHON" ] && [ -x "$VP_MODELS_PYTHON" ] || exit 64
[ -f "$VP_MODELS_DIR/online_models_worker.py" ] && [ -f "$VP_MODELS_DIR/groq-models.sb" ] || exit 64
exec /usr/bin/env -i PATH=/usr/bin:/bin PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
  /usr/bin/sandbox-exec -D "BACKEND_ROOT=$VP_MODELS_DIR" -D "ASSET_ROOT=$VP_MODELS_ASSETS" \
  -f "$VP_MODELS_DIR/groq-models.sb" "$VP_MODELS_PYTHON" -I -B "$VP_MODELS_DIR/online_models_worker.py" groq
