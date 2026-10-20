#!/usr/bin/env bash
# Compile the unit's /system/framework/services.jar ahead of time and keep the
# result in gsi/odex-cache/services-<key>/, where izm-audio.sh,
# microg-gsi.sh and seamless-scale-gsi.sh pick it up.
#
# patch-services.py, microg/MicrogSpoofFix.java and
# compat-scale/SeamlessScaleFix.java change services.jar, so
# the GSI's own odex, vdex and art no longer match and have to go;
# system_server then runs its services from the interpreter and JIT. This rebuilds them the way the
# GSI build did (compiler filter speed, class loader context
# PCL[com.android.location.provider.jar], the boot image on /system), with
# the unit's own dex2oat. Run it with the unit booted from an image whose
# services.jar came from the script that needs the odex, as root (adb root).
# The work directory on the unit is reused and left in place: deletions on the
# unit are the user's to make.
#
# Usage: scripts/services-odex.sh [adb-serial]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB=("$ROOT/tools/platform-tools/adb" -s "${1:-${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb serial of the unit}}")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
T=/data/local/tmp/services-odex

"${ADB[@]}" pull /system/framework/services.jar "$WORK/services.jar" >/dev/null
KEY=$(env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/dex-key.py" "$WORK/services.jar")
OUT="$ROOT/gsi/odex-cache/services-$KEY"

# -Xmx512m as in the build: a larger heap asks for twice that in one
# low-memory mapping, which this unit cannot give.
"${ADB[@]}" shell "mkdir -p $T && /apex/com.android.art/bin/dex2oat64 \
	--runtime-arg -Xms64m --runtime-arg -Xmx512m \
	--runtime-arg -Xbootclasspath:\$BOOTCLASSPATH \
	--runtime-arg -Xbootclasspath-locations:\$BOOTCLASSPATH \
	--boot-image=/system/framework/boot.art:/system/framework/boot-framework.art \
	--android-root=/system \
	--dex-file=/system/framework/services.jar \
	--dex-location=/system/framework/services.jar \
	--oat-file=$T/services.odex --app-image-file=$T/services.art \
	--profile-file=/system/framework/services.jar.prof \
	--class-loader-context='PCL[/system/framework/com.android.location.provider.jar]' \
	--instruction-set=arm64 --instruction-set-variant=cortex-a53 \
	--instruction-set-features=default --compiler-filter=speed \
	--compilation-reason=prebuilt --generate-mini-debug-info -j4"

mkdir -p "$OUT"
for x in odex vdex art; do
	"${ADB[@]}" pull "$T/services.$x" "$OUT/services.$x" >/dev/null
done
echo "$OUT"
