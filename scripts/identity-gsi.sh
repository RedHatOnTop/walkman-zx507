#!/usr/bin/env bash
# The unit reports itself as Sony's NW-ZX500Series again, as on stock (devlog 2026-10-19).
#
# A13 init fills ro.product.{brand,device,manufacturer,model,name} from the first partition in
# ro.product.property_source_order that sets them, product first by default, so the GSI's
# product build.prop ("TrebleDroid vanilla", manufacturer "unknown") hides the vendor's
# (SonyAudio, icx1295, Sony, NW-ZX500Series, icx1295_002). build.prop puts the vendor first.
# The fingerprint stays the GSI's. Settings stores the device and Bluetooth names from
# Build.MODEL on first boot, so a unit set up on an earlier image keeps "TrebleDroid vanilla"
# there until it is renamed in Settings, About.
#
# Usage: scripts/identity-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ORDER=vendor,odm,product,system_ext,system

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

debugfs -R "dump /system/build.prop $WORK/build.prop" "$OUT" 2>/dev/null
! grep -q '^ro\.product\.property_source_order=' "$WORK/build.prop" ||
	{ echo "build.prop: ro.product.property_source_order already set" >&2; exit 1; }
printf '\n# device identity from the vendor (NW-ZX500Series), as on stock\nro.product.property_source_order=%s\n' \
	$ORDER >>"$WORK/build.prop"
bmode=$(debugfs -R "stat /system/build.prop" "$OUT" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p')

cat >"$WORK/cmds" <<EOF
rm /system/build.prop
write $WORK/build.prop /system/build.prop
sif /system/build.prop mode 0100$bmode
sif /system/build.prop uid 0
sif /system/build.prop gid 0
ea_set -f $WORK/ctx-system /system/build.prop security.selinux
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
echo "$OUT: ro.product.* from the vendor first ($ORDER)"
