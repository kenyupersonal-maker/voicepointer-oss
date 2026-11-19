#!/bin/bash
# Isolated maintenance of the hash-restored 04 tree; never builds latest Sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/IntegratedPreview/Maintenance04/Sources"
OUT="$ROOT/.cache/maintenance04-build"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
TOOLCHAIN=/Library/Developer/CommandLineTools/usr/bin
mkdir -p "$OUT"
export SWIFT_USE_OLD_DRIVER=1
COMMON=(-parse-as-library -swift-version 6 -warnings-as-errors -target arm64-apple-macosx14.0 -sdk "$SDK" -module-cache-path "$ROOT/.cache/swift")
INCLUDES=(-I "$SRC/CMultitouchSupport/include" -I "$SRC/CAudioMeterSupport/include" -I "$OUT")
FRAMEWORKS=(-framework AppKit -framework ApplicationServices -framework CoreGraphics -framework Carbon -framework IOKit -framework AVFoundation -framework ServiceManagement)
"$TOOLCHAIN/clang" -target arm64-apple-macosx14.0 -isysroot "$SDK" -I "$SRC/CMultitouchSupport/include" -c "$SRC/CMultitouchSupport/shim.c" -o "$OUT/multitouch.o"
"$TOOLCHAIN/clang" -target arm64-apple-macosx14.0 -isysroot "$SDK" -fobjc-arc -I "$SRC/CAudioMeterSupport/include" -c "$SRC/CAudioMeterSupport/CAudioMeterSupport.m" -o "$OUT/audio.o"
CORE=(); APP=(); CHECKS=()
while IFS= read -r path; do CORE+=("$path"); done < <(/usr/bin/find "$SRC/VoicePointerCore" -type f -name '*.swift' -print | sort)
while IFS= read -r path; do APP+=("$path"); done < <(/usr/bin/find "$SRC/VoicePointer" -type f -name '*.swift' -print | sort)
while IFS= read -r path; do CHECKS+=("$path"); done < <(/usr/bin/find "$SRC/VoicePointerSelfTest" -type f -name '*.swift' -print | sort)
"$TOOLCHAIN/swiftc" "${COMMON[@]}" "${INCLUDES[@]}" -module-name VoicePointerCore -emit-module -emit-module-path "$OUT/VoicePointerCore.swiftmodule" -emit-library -static "${CORE[@]}" -o "$OUT/libVoicePointerCore.a"
"$TOOLCHAIN/swiftc" "${COMMON[@]}" "${INCLUDES[@]}" "${APP[@]}" "$OUT/libVoicePointerCore.a" "$OUT/multitouch.o" "$OUT/audio.o" "${FRAMEWORKS[@]}" -o "$OUT/VoicePointerPreview"
"$TOOLCHAIN/swiftc" "${COMMON[@]}" "${INCLUDES[@]}" "${CHECKS[@]}" "$OUT/libVoicePointerCore.a" "$OUT/multitouch.o" "$OUT/audio.o" "${FRAMEWORKS[@]}" -o "$OUT/VoicePointerPreviewSelfTest"
echo MAINTENANCE04_BUILD_PASS
