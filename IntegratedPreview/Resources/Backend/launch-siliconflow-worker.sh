#!/bin/bash
# Fixed SiliconFlow component; credentials arrive through stdin only.
set -eu
[ "$#" -eq 0 ] || exit 64
VP_SILICON_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
VP_SILICON_ASSETS=$(cd -P "$VP_SILICON_DIR/../Seed/payload" && pwd -P)
VP_SILICON_PYTHON="$VP_SILICON_ASSETS/.cache/venvs/voicenative-beta/bin/python"
[ -f "$VP_SILICON_PYTHON" ] && [ -x "$VP_SILICON_PYTHON" ] || exit 64
[ -f "$VP_SILICON_DIR/cloud_openai_worker.py" ] && [ ! -L "$VP_SILICON_DIR/cloud_openai_worker.py" ] || exit 64
[ -f "$VP_SILICON_DIR/siliconflow-worker.sb" ] && [ ! -L "$VP_SILICON_DIR/siliconflow-worker.sb" ] || exit 64
exec /usr/bin/env -i PATH=/usr/bin:/bin PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
  /usr/bin/sandbox-exec -D "BACKEND_ROOT=$VP_SILICON_DIR" -D "ASSET_ROOT=$VP_SILICON_ASSETS" \
  -f "$VP_SILICON_DIR/siliconflow-worker.sb" "$VP_SILICON_PYTHON" -I -B "$VP_SILICON_DIR/cloud_openai_worker.py" siliconflow
