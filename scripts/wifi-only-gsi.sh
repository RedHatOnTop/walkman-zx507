#!/usr/bin/env bash
# The ZX507 is Wi-Fi only. Turns the GSI's phone stack off the way AOSP
# configures a Wi-Fi-only tablet:
#
# - ZX507WifiOnly (gsi-overlays/wifionly, static, built against the image's
#   framework-res): config_voice_capable, config_sms_capable and
#   config_mobile_data_capable false, so TelephonyManager reports no modem
#   and the phone process creates no Phone objects.
# - gsi-etc/zx507-wifi-only.xml in /system/etc/permissions: unavailable-feature
#   for the telephony, IMS and SIP features, so Settings and SystemUI hide
#   the mobile network UI. android.software.telecom stays.
#
# Before (zxdbg15, devlog 2026-10-15 23:39): com.android.phone 123 MB RSS and
# the cell broadcast receiver 99 MB, with ro.radio.noril=yes already set.
#
# Usage: scripts/wifi-only-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OVL=/system/product/overlay/ZX507WifiOnly
XML=/system/etc/permissions/zx507-wifi-only.xml

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

debugfs -R "dump /system/framework/framework-res.apk $WORK/framework-res.apk" "$OUT" 2>/dev/null
"$ROOT/scripts/build-overlay.sh" wifionly "$WORK/framework-res.apk" "$WORK/overlay.apk"

cat >"$WORK/cmds" <<CMDS
mkdir $OVL
sif $OVL mode 040755
ea_set -f $WORK/ctx-system $OVL security.selinux
write $WORK/overlay.apk $OVL/ZX507WifiOnly.apk
sif $OVL/ZX507WifiOnly.apk mode 0100644
sif $OVL/ZX507WifiOnly.apk uid 0
sif $OVL/ZX507WifiOnly.apk gid 0
ea_set -f $WORK/ctx-system $OVL/ZX507WifiOnly.apk security.selinux
write $ROOT/gsi-etc/zx507-wifi-only.xml $XML
sif $XML mode 0100644
sif $XML uid 0
sif $XML gid 0
ea_set -f $WORK/ctx-system $XML security.selinux
CMDS

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
echo "$OUT: Wi-Fi only"
