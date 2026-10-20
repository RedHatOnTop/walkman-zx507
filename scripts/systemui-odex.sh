#!/usr/bin/env bash
# Compile the unit's SystemUI.apk ahead of time and keep the result in
# gsi/odex-cache/systemui-<key>/, where lean-ui-gsi.sh picks it up.
#
# patch-systemui.py changes classes.dex, so the GSI's own oat/arm64 odex and
# vdex no longer match; `cmd package compile` then fails on the stale vdex
# (dex2oat: "Vdex file checksum different than source dex checksum") and
# SystemUI runs from the interpreter and JIT. This compiles with the compiler
# filter the QS measurements of 2026-10-16 used (speed) and the class loader
# context package manager gives SystemUI (PCL[]), with the unit's own dex2oat.
# Run it as root (adb root) with the unit's SystemUI.apk being the patched one:
# booted from an image made by lean-ui-gsi.sh, or with the patched APK
# bind-mounted over /system/system_ext/priv-app/SystemUI/SystemUI.apk.
#
# Usage: scripts/systemui-odex.sh [adb-serial]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB=("$ROOT/tools/platform-tools/adb" -s "${1:-${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb serial of the unit}}")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APK=/system/system_ext/priv-app/SystemUI/SystemUI.apk
T=/data/local/tmp/systemui-odex/$(date +%s)

"${ADB[@]}" pull "$APK" "$WORK/SystemUI.apk" >/dev/null
KEY=$(env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/dex-key.py" "$WORK/SystemUI.apk")
OUT="$ROOT/gsi/odex-cache/systemui-$KEY"

# -Xmx512m as in the build: a larger heap asks for twice that in one
# low-memory mapping, which this unit cannot give.
"${ADB[@]}" shell "mkdir -p $T && /apex/com.android.art/bin/dex2oat64 \
	--runtime-arg -Xms64m --runtime-arg -Xmx512m \
	--runtime-arg -Xbootclasspath:\$BOOTCLASSPATH \
	--runtime-arg -Xbootclasspath-locations:\$BOOTCLASSPATH \
	--boot-image=/system/framework/boot.art:/system/framework/boot-framework.art \
	--android-root=/system \
	--dex-file=$APK --dex-location=$APK \
	--oat-file=$T/SystemUI.odex \
	--class-loader-context='PCL[]{}' --classpath-dir=$(dirname $APK) \
	--instruction-set=arm64 --instruction-set-variant=cortex-a53 \
	--instruction-set-features=default --compiler-filter=speed \
	--compilation-reason=prebuilt --resolve-startup-const-strings=true \
	--generate-mini-debug-info -j4"

mkdir -p "$OUT"
for x in odex vdex; do
	"${ADB[@]}" pull "$T/SystemUI.$x" "$OUT/SystemUI.$x" >/dev/null
done
echo "$OUT"
