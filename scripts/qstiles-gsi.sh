#!/usr/bin/env bash
# Quick Settings down to five tiles on a GSI image copy (devlog 2026-10-19).
#
# - gsi-overlays/qstiles (ZX507QsTiles, static) sets SystemUI's default tile list to Internet,
#   Bluetooth, Do Not Disturb, auto-rotate and Battery Saver. It applies to a unit whose
#   sysui_qs_tiles is unset (first boot) or says "default", and to the tile editor's Reset.
# - gsi-init/zx507-qstiles.rc + zx507-qstiles-default.sh: once, after the first boot, drop the
#   memory tile a debuggable SystemUI appends to that default.
#
# Android still adds a tile by itself when the owner turns its feature on elsewhere (hotspot,
# color inversion, ...).
#
# Usage: scripts/qstiles-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OVL=/system/product/overlay/ZX507QsTiles
RC=/system/etc/init/zx507-qstiles.rc
SEED=/system/bin/zx507-qstiles-default.sh

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"
printf '%s\0' u:object_r:phhsu_exec:s0 >"$WORK/ctx-phhsu"

for f in $OVL $RC $SEED; do
	if debugfs -R "stat $f" "$OUT" 2>/dev/null | grep -q '^Inode:'; then
		echo "$IN: $f already exists" >&2
		exit 1
	fi
done
debugfs -R "dump /system/framework/framework-res.apk $WORK/framework-res.apk" "$OUT" 2>/dev/null
"$ROOT/scripts/build-overlay.sh" qstiles "$WORK/framework-res.apk" "$WORK/overlay.apk"

cat >"$WORK/cmds" <<EOF
mkdir $OVL
sif $OVL mode 040755
ea_set -f $WORK/ctx-system $OVL security.selinux
write $WORK/overlay.apk $OVL/ZX507QsTiles.apk
sif $OVL/ZX507QsTiles.apk mode 0100644
sif $OVL/ZX507QsTiles.apk uid 0
sif $OVL/ZX507QsTiles.apk gid 0
ea_set -f $WORK/ctx-system $OVL/ZX507QsTiles.apk security.selinux
write $ROOT/gsi-init/zx507-qstiles.rc $RC
sif $RC mode 0100644
sif $RC uid 0
sif $RC gid 0
ea_set -f $WORK/ctx-system $RC security.selinux
write $ROOT/gsi-init/zx507-qstiles-default.sh $SEED
sif $SEED mode 0100755
sif $SEED uid 0
sif $SEED gid 2000
ea_set -f $WORK/ctx-phhsu $SEED security.selinux
EOF

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
echo "$OUT: Quick Settings default tiles internet,bt,dnd,rotation,battery"
