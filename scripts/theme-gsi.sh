#!/usr/bin/env bash
# The ZX507's default system theme: OLED black with Sony's champagne gold
# (devlog 2026-10-15). Sony's own apps keep their look; this changes only the
# system's.
#
# - gsi-overlays/blackgold (ZX507BlackGold, static, built against the image's
#   framework-res): dark mode by default, black window backgrounds, Monet's
#   warm near-black for floating surfaces, and accents one tone down.
# - gsi-init/zx507-theme.rc + zx507-theme-default.sh: on the first boot,
#   seed Monet with W.music's gold (#C0A565) unless a theme is already set.
#
# Usage: scripts/theme-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OVL=/system/product/overlay/ZX507BlackGold
RC=/system/etc/init/zx507-theme.rc
SEED=/system/bin/zx507-theme-default.sh

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"
printf '%s\0' u:object_r:phhsu_exec:s0 >"$WORK/ctx-phhsu"

debugfs -R "dump /system/framework/framework-res.apk $WORK/framework-res.apk" "$OUT" 2>/dev/null
"$ROOT/scripts/build-overlay.sh" blackgold "$WORK/framework-res.apk" "$WORK/overlay.apk"

cat >"$WORK/cmds" <<EOF
mkdir $OVL
sif $OVL mode 040755
ea_set -f $WORK/ctx-system $OVL security.selinux
write $WORK/overlay.apk $OVL/ZX507BlackGold.apk
sif $OVL/ZX507BlackGold.apk mode 0100644
sif $OVL/ZX507BlackGold.apk uid 0
sif $OVL/ZX507BlackGold.apk gid 0
ea_set -f $WORK/ctx-system $OVL/ZX507BlackGold.apk security.selinux
write $ROOT/gsi-init/zx507-theme.rc $RC
sif $RC mode 0100644
sif $RC uid 0
sif $RC gid 0
ea_set -f $WORK/ctx-system $RC security.selinux
write $ROOT/gsi-init/zx507-theme-default.sh $SEED
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
echo "$OUT: black and gold system theme"
