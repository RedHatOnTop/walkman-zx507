#!/usr/bin/env bash
# Less GPU work per UI frame on a GSI image copy (devlog 2026-10-16). The
# GC7000NanoUltra is bound by the pixels it fills, so this cuts pixels and
# lets frames absorb the slow ones:
#
# - SystemUI gets scripts/patch-systemui.py: LightRevealScrim no longer
#   blends a transparent full-screen rect on every shade frame, and the QS
#   footer no longer marquees the build number (a CPU copy after a full GPU
#   drain on every QS frame). scripts/SysuiCompatFix.java then keeps
#   Android 13 from scaling its resources twice when it runs downscaled. Its
#   oat/arm64 odex and vdex are replaced from gsi/odex-cache/systemui-<dex
#   key> (scripts/systemui-odex.sh) when that exists and removed otherwise,
#   since the stock ones no longer match.
# - SystemUI renders at 0.75 scale (540x960 / 270 dpi) from the first boot
#   (gsi-init/zx507-sysui-scale.rc); the HWC scales its windows to the panel.
#   The display stays 720x1280 for Sony's apps, which break at any other
#   size. QS and shade gestures at 720x1280: 71-73 missed vsyncs -> 40-42.
# - SurfaceFlinger gives the app 50 ms (three vsyncs) instead of 33.3 ms, so
#   one slow frame fits in the pipeline. Missed vsyncs over QS and shade
#   gestures at 540x960: 65-72 -> 58-59. Costs one frame of touch latency.
# - phh-on-boot.sh bind-mounts libminijail.so onto its own path on every
#   sys.boot_completed=1, which a framework restart sets again; mount
#   propagation doubles the stack each time (2044 mounts after nine), and
#   every df and mount-table reader slows with it (df 1.4 s). The block now
#   runs only while no libminijail mount exists.
#
# Usage: scripts/lean-ui-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BT="$ROOT/tools/build-tools-dl/x/android-14"
KEYS="$ROOT/tools/aosp-testkeys"
DEXLIB2="$ROOT/tools/dexlib2-dl/dexlib2-2.5.2.jar:$ROOT/tools/dexlib2-dl/guava-27.1-android.jar"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SYSUI=/system/system_ext/priv-app/SystemUI/SystemUI.apk
SYSUI_OAT=/system/system_ext/priv-app/SystemUI/oat/arm64/SystemUI
PHH=/system/bin/phh-on-boot.sh
PHH_SHA256=b67f17ae57f52ccefb6caec5532c772b85dbbec2cbba92abbd77fb11222d79a8
RC=/system/etc/init/zx507-sysui-scale.rc
SH=/system/bin/zx507-sysui-scale-default.sh

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"
printf '%s\0' u:object_r:phhsu_exec:s0 >"$WORK/ctx-phhsu"

debugfs -R "dump $SYSUI $WORK/SystemUI.apk" "$OUT" 2>/dev/null
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/patch-systemui.py" \
	"$WORK/SystemUI.apk" "$WORK/sysui-patched.apk"
java -Xmx3g -cp "$DEXLIB2" "$ROOT/scripts/SysuiCompatFix.java" \
	"$WORK/sysui-patched.apk" "$WORK/sysui-unsigned.apk"
"$BT/zipalign" -p -f 4 "$WORK/sysui-unsigned.apk" "$WORK/sysui-aligned.apk"
"$BT/apksigner" sign --key "$KEYS/platform.pk8" --cert "$KEYS/platform.x509.pem" \
	--out "$WORK/SystemUI-patched.apk" "$WORK/sysui-aligned.apk"
"$BT/apksigner" verify "$WORK/SystemUI-patched.apk"
KEY=$(env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/dex-key.py" "$WORK/SystemUI-patched.apk")
ODEX="$ROOT/gsi/odex-cache/systemui-$KEY"
if [ ! -s "$ODEX/SystemUI.odex" ]; then
	echo "no $ODEX: SystemUI runs without odex (see scripts/systemui-odex.sh)" >&2
	ODEX=
fi

debugfs -R "dump $PHH $WORK/phh-on-boot.sh" "$OUT" 2>/dev/null
[ "$(sha256sum "$WORK/phh-on-boot.sh" | cut -d' ' -f1)" = $PHH_SHA256 ] ||
	{ echo "$PHH: unexpected sha256" >&2; exit 1; }
sed -i -E 's/^if \[ "\$vndk" = (27|28) \];then$/if [ "$vndk" = \1 ] \&\& ! grep -q libminijail \/proc\/mounts;then/' \
	"$WORK/phh-on-boot.sh"
[ "$(grep -c '! grep -q libminijail /proc/mounts' "$WORK/phh-on-boot.sh")" = 2 ] ||
	{ echo "$PHH: minijail blocks not found" >&2; exit 1; }

debugfs -R "dump /system/build.prop $WORK/build.prop" "$OUT" 2>/dev/null
for p in late early earlyGl; do
	grep -qx "debug.sf.$p.app.duration=33300000" "$WORK/build.prop" ||
		{ echo "build.prop: no debug.sf.$p.app.duration=33300000 (compat-gsi.sh)" >&2; exit 1; }
	sed -i "s/^debug.sf.$p.app.duration=33300000$/debug.sf.$p.app.duration=50000000/" "$WORK/build.prop"
done
bmode=$(debugfs -R "stat /system/build.prop" "$OUT" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p')

file() {
	cat <<EOF
write $1 $2
sif $2 mode 0100${4:-644}
sif $2 uid 0
sif $2 gid ${5:-0}
ea_set -f $WORK/ctx-${3:-system} $2 security.selinux
EOF
}
{
	echo "rm $SYSUI"
	file "$WORK/SystemUI-patched.apk" $SYSUI
	for x in odex vdex; do
		echo "rm $SYSUI_OAT.$x"
		[ -z "$ODEX" ] || file "$ODEX/SystemUI.$x" "$SYSUI_OAT.$x"
	done
	echo "rm $PHH"
	file "$WORK/phh-on-boot.sh" $PHH phhsu 755 2000
	echo "rm /system/build.prop"
	file "$WORK/build.prop" /system/build.prop system "$bmode"
	file "$ROOT/gsi-init/zx507-sysui-scale.rc" $RC
	file "$ROOT/gsi-init/zx507-sysui-scale-default.sh" $SH phhsu 755 2000
} >"$WORK/cmds"

truncate -s "$PART_BYTES" "$OUT"
resize2fs "$OUT" >/dev/null
debugfs -w -f "$WORK/cmds" "$OUT" >"$WORK/debugfs.log" 2>&1
if grep -vE '^(debugfs [0-9.]+ \(|debugfs: |Allocated inode: [0-9]+$|$)' "$WORK/debugfs.log" | grep -q .; then
	cat "$WORK/debugfs.log" >&2
	exit 1
fi
e2fsck -fn "$OUT" >/dev/null
resize2fs -M "$OUT" >/dev/null
blocks=$(dumpe2fs -h "$OUT" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2); print $2}')
truncate -s $((blocks * 4096)) "$OUT"
e2fsck -fn "$OUT" >/dev/null
echo "$OUT: lean UI (SystemUI patches at 0.75 scale, 50 ms app budget, minijail mount guard)"
