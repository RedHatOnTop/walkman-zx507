#!/usr/bin/env bash
# Hand the ZX507's output selection and volume back to Sony's own services on
# the Android 13 GSI (devlog 2026-10-15):
#
# - IzmAudioManager gets scripts/patch-izmaudio.py: it now selects the wired
#   output (izm_output_device=hp_se) when AudioService already knows the jack.
#   Without it the HAL stays on izm_output_device=none and nothing is heard.
# - gsi-overlays/sonyvolume: global_keys.xml sends both volume keys to
#   VolumeCtrlPanelApp's MasterVolumeReceiver, as stock framework-res did, so
#   they move the codec's master volume instead of STREAM_MUSIC.
# - services.jar gets scripts/patch-services.py, so those keys, marked
#   dispatchWhenNonInteractive, also work with the screen off. Its odex, vdex
#   and art no longer match the jar. They are replaced from
#   gsi/odex-cache/services-<dex key> (scripts/services-odex.sh, compiled on
#   the unit) when that exists, and removed otherwise, which leaves
#   system_server's services to the interpreter and JIT.
# - The stock /system/etc/permissions/amb-battery-exceptions.xml, Sony's
#   power-save allowlist. VolumeCtrlPanelApp starts its MasterVolumeService
#   from a broadcast receiver, which Android 13 refuses to a background app
#   that is not on that list (so are BatteryCtrlService, StorageMonitorService
#   and FuncCore).
# - apps/volumedial (ZX507VolumeDial, persistent, platform-signed): the
#   master-volume popup that stock Sony SystemUI showed on a volume key, the
#   number and its 20-tick meter. A tap opens VolumeCtrlPanelApp's own big
#   dial. AOSP's SystemUI has no such row.
#
# Run on an image that already has the Sony apps (add-sony-apps.sh). Every
# Sony file comes from the operator's own images and stays on this machine.
#
# Usage: scripts/izm-audio.sh <in.img> <out.img> <stock-system.img>

set -euo pipefail
IN="$1"
OUT="$2"
STOCK="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BT="$ROOT/tools/build-tools-dl/x/android-14"
KEYS="$ROOT/tools/aosp-testkeys"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

IZM=/system/priv-app/IzmAudioManager/IzmAudioManager.apk
OVL=/system/product/overlay/ZX507SonyVolume
EXC=/system/etc/permissions/amb-battery-exceptions.xml
SVC=/system/framework/services.jar
SVC_OAT=/system/framework/oat/arm64/services
DIAL=/system/app/ZX507VolumeDial

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

debugfs -R "dump $IZM $WORK/izm.apk" "$OUT" 2>/dev/null
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/patch-izmaudio.py" \
	"$WORK/izm.apk" "$WORK/izm-unsigned.apk"
"$BT/zipalign" -p -f 4 "$WORK/izm-unsigned.apk" "$WORK/izm-aligned.apk"
"$BT/apksigner" sign --key "$KEYS/platform.pk8" --cert "$KEYS/platform.x509.pem" \
	--out "$WORK/izm-patched.apk" "$WORK/izm-aligned.apk"
"$BT/apksigner" verify "$WORK/izm-patched.apk"

debugfs -R "dump /system/framework/framework-res.apk $WORK/framework-res.apk" "$OUT" 2>/dev/null
"$ROOT/scripts/build-overlay.sh" sonyvolume "$WORK/framework-res.apk" "$WORK/overlay.apk"

debugfs -R "dump $SVC $WORK/services.jar" "$OUT" 2>/dev/null
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/patch-services.py" \
	"$WORK/services.jar" "$WORK/services-unaligned.jar"
"$BT/zipalign" -p -f 4 "$WORK/services-unaligned.jar" "$WORK/services-patched.jar"
KEY=$(env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/dex-key.py" "$WORK/services-patched.jar")
ODEX="$ROOT/gsi/odex-cache/services-$KEY"
if [ ! -s "$ODEX/services.odex" ]; then
	echo "no $ODEX: services.jar runs without odex (see scripts/services-odex.sh)" >&2
	ODEX=
fi

if [ -n "${KIT_FROM_SOURCE:-}" ]; then
	"$ROOT/apps/volumedial/build.sh" "$WORK/volumedial.apk" >/dev/null
else
	"$ROOT/scripts/prebuilt.sh" ZX507VolumeDial.apk "$WORK/volumedial.apk"
fi

debugfs -R "dump $EXC $WORK/exceptions.xml" "$STOCK" 2>/dev/null
grep -q 'allow-in-power-save package="com.sony.walkman.volumectrlpanel"' "$WORK/exceptions.xml" ||
	{ echo "$STOCK: no volumectrlpanel in $EXC" >&2; exit 1; }

file() {
	cat <<EOF
write $1 $2
sif $2 mode 0100644
sif $2 uid 0
sif $2 gid 0
ea_set -f $WORK/ctx-system $2 security.selinux
EOF
}
{
	echo "rm $IZM"
	file "$WORK/izm-patched.apk" $IZM
	cat <<EOF
mkdir $OVL
sif $OVL mode 040755
ea_set -f $WORK/ctx-system $OVL security.selinux
EOF
	file "$WORK/overlay.apk" $OVL/ZX507SonyVolume.apk
	file "$WORK/exceptions.xml" $EXC
	echo "rm $SVC"
	file "$WORK/services-patched.jar" $SVC
	for x in odex vdex art; do
		# An earlier step without a cached odex already took them out.
		if debugfs -R "stat $SVC_OAT.$x" "$OUT" 2>/dev/null | grep -q '^Inode:'; then
			echo "rm $SVC_OAT.$x"
		fi
		[ -z "$ODEX" ] || file "$ODEX/services.$x" "$SVC_OAT.$x"
	done
	cat <<EOF
mkdir $DIAL
sif $DIAL mode 040755
ea_set -f $WORK/ctx-system $DIAL security.selinux
EOF
	file "$WORK/volumedial.apk" $DIAL/ZX507VolumeDial.apk
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
echo "$OUT: IzmAudioManager output fix, Sony volume keys (also screen off), power-save allowlist, volume popup"
