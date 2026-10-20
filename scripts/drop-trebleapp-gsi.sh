#!/usr/bin/env bash
# TrebleDroid's settings app (me.phh.treble.app, "Phh Treble Settings") out of a GSI image copy
# (devlog 2026-10-19).
#
# It is a quirk menu for phones from other vendors (Huawei, Samsung, Qualcomm, MediaTek, ...),
# and on the ZX507 it only writes defaults back at boot: everything this image depends on is in
# build.prop or the scripts here (system_audio_hal from TrebleDroid's system.prop, the Bluetooth
# vendor-capability cap from compat-gsi.sh). Its persist.sys.bt.unsupport.* are not the
# persist.sys.bt.unsupported.* the A13 Bluetooth stack reads. It ran as a persistent app
# (13 MB PSS), asked raw.githubusercontent.com for presets on every boot, and put its menu at
# the top of Settings.
#
# Usage: scripts/drop-trebleapp-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP=/system/priv-app/TrebleApp
PRIV_XML=/system/etc/permissions/privapp-permissions-me.phh.treble.app.xml

cp --reflink=auto "$IN" "$OUT"

for f in $APP/TrebleApp.apk $APP/oat/arm64/TrebleApp.odex $APP/oat/arm64/TrebleApp.vdex $PRIV_XML; do
	debugfs -R "stat $f" "$OUT" 2>/dev/null | grep -q '^Inode:' || { echo "$IN: no $f" >&2; exit 1; }
done

cat >"$WORK/cmds" <<EOF
rm $APP/oat/arm64/TrebleApp.odex
rm $APP/oat/arm64/TrebleApp.vdex
rmdir $APP/oat/arm64
rmdir $APP/oat
rm $APP/TrebleApp.apk
rmdir $APP
rm $PRIV_XML
EOF

truncate -s "$PART_BYTES" "$OUT"
resize2fs "$OUT" >/dev/null
debugfs -w -f "$WORK/cmds" "$OUT" >"$WORK/debugfs.log" 2>&1
if grep -vE '^(debugfs [0-9.]+ \(|debugfs: |$)' "$WORK/debugfs.log" | grep -q .; then
	cat "$WORK/debugfs.log" >&2
	exit 1
fi
e2fsck -fn "$OUT" >/dev/null
resize2fs -M "$OUT" >/dev/null
blocks=$(dumpe2fs -h "$OUT" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2); print $2}')
truncate -s $((blocks * 4096)) "$OUT"
e2fsck -fn "$OUT" >/dev/null
echo "$OUT: TrebleDroid settings app gone"
