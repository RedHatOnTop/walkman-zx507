#!/usr/bin/env bash
# The ZX507 system image from TrebleDroid's GSI and the unit's own stock 4.06 images, every step
# in the order the debug builds took them (devlog 2026-10-20). The stock images supply the
# boot animation, Sony's apps and libraries and the Vivante driver; none of that is in this
# repository.
#
# The debug build (the default) has the /init wrapper, root telnet and adb over USB from boot
# (debug-gsi.sh). RELEASE=1 builds without them, with adb asking per computer, USB as MTP and,
# unless KEEP_SU=1, no root (release-gsi.sh).
#
# refresh-debug-wrapper.sh is not a step: debug-gsi.sh already writes the current gsi-debug/
# files. The last step compiles services.jar and SystemUI on the host, so the odex the earlier
# steps take from gsi/odex-cache/ (or leave out) do not reach the result.
#
# Usage: [RELEASE=1 [KEEP_SU=1]] scripts/build-image.sh <gsi.img> <stock-system.img> \
#            <stock-vendor.img> <out.img>
#        [RELEASE=1] scripts/build-image.sh --count    (the number of steps it would run)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUSYBOX="$ROOT/tools/busybox-dl/x/usr/bin/busybox"
BT="$ROOT/tools/build-tools-dl/x/android-14"

steps() {
	BOOTANIM="$WORK/bootanimation.zip" step prepare-gsi
	[ -n "${RELEASE:-}" ] || step debug-gsi "$BUSYBOX"
	step add-sony-apps "$STOCK_SYSTEM" "$BT"
	WALLPAPER="$WORK/wallpaper.png" step debloat-gsi
	step compat-gsi
	step wmusic-audio
	step izm-audio "$STOCK_SYSTEM"
	step theme-gsi
	step gpu-gsi "$STOCK_VENDOR"
	step wifi-only-gsi
	step lean-ui-gsi
	step tag-charset-gsi
	step microg-gsi
	step seamless-scale-gsi
	step identity-gsi
	step wallpaper-gsi
	step firefox-gsi
	step qstiles-gsi
	step drop-trebleapp-gsi
	[ -z "${RELEASE:-}" ] || step release-gsi
	step odex-gsi
}

n=0
if [ "${1:-}" = --count ]; then
	step() { n=$((n + 1)); }
	WORK= STOCK_SYSTEM= STOCK_VENDOR=
	steps
	echo "$n"
	exit 0
fi

GSI="$1"
STOCK_SYSTEM="$2"
STOCK_VENDOR="$3"
OUT="$4"

[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
for f in "$GSI" "$STOCK_SYSTEM" "$STOCK_VENDOR" "$BUSYBOX" "$BT/apksigner"; do
	[ -e "$f" ] || { echo "no $f" >&2; exit 1; }
done
# Next to <out.img>, so each step's copy is a reflink of the one before.
WORK="$(mktemp -d "$(dirname "$OUT")/.build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

debugfs -R "dump /system/media/bootanimation.zip $WORK/bootanimation.zip" "$STOCK_SYSTEM" 2>/dev/null
debugfs -R "dump /system/framework/framework-res.apk $WORK/framework-res.apk" "$STOCK_SYSTEM" 2>/dev/null
unzip -q -p "$WORK/framework-res.apk" res/drawable-nodpi-v4/default_wallpaper.png >"$WORK/wallpaper.png"
for f in bootanimation.zip wallpaper.png; do
	[ -s "$WORK/$f" ] || { echo "$STOCK_SYSTEM: no stock $f" >&2; exit 1; }
done

cur="$GSI"
step() {
	n=$((n + 1))
	local next
	next="$WORK/$(printf %02d $n)-$1.img"
	echo "== $n $1"
	"$ROOT/scripts/$1.sh" "$cur" "$next" "${@:2}"
	cur="$next"
}
steps
mv "$cur" "$OUT"
echo "$OUT: $n steps"
