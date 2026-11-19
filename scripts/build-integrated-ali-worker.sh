#!/bin/bash
# Builds the Ali realtime worker from the committed worker sources. The optional argument is where to write it
# (default: the donor build location). The packaging step and check.sh pass a path of their own, so a bundled or
# tested worker is never a leftover from an earlier build.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$#" -le 1 ]] || { echo 'usage: build-integrated-ali-worker.sh [output path]' >&2; exit 64; }
OUT="${1:-$ROOT/.cache/integrated-preview-direct/AliRealtimeWorker}"
export SWIFT_USE_OLD_DRIVER=1
mkdir -p "$ROOT/.cache/swift" "$(dirname "$OUT")"
CORE="$ROOT/IntegratedPreview/Sources/VoicePointerCore/Voice"
WORKER="$ROOT/IntegratedPreview/CloudWorker"
/Library/Developer/CommandLineTools/usr/bin/swiftc \
  -parse-as-library \
  -swift-version 6 \
  -warnings-as-errors \
  -target arm64-apple-macosx14.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -module-cache-path "$ROOT/.cache/swift" \
  "$CORE/AliEndpoint.swift" \
  "$CORE/AliServiceFailure.swift" \
  "$CORE/AliRecognitionHints.swift" \
  "$CORE/AliWireCodec.swift" \
  "$CORE/AliTranscriptAssembler.swift" \
  "$CORE/AliIPC.swift" \
  "$CORE/DuplexLineIO.swift" \
  "$WORKER/AliWebSocketConnection.swift" \
  "$WORKER/AliStreamSession.swift" \
  "$WORKER/AliWorkerMain.swift" \
  -o "$OUT"
echo ALI_WORKER_BUILD_PASS
