#!/usr/bin/env bash
# Default wallpaper drawn by wallpaper/onebit.py instead of the stock plain black one
# (devlog 2026-10-19). debloat-gsi.sh already points ro.config.wallpaper at
# /system/media/default_wallpaper.png; this replaces that file. A unit with no wallpaper of its
# own set shows the new one after the reboot; one the user picked stays.
#
# Usage: scripts/wallpaper-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

WP=/system/media/default_wallpaper.png

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

debugfs -R "dump /system/build.prop $WORK/build.prop" "$OUT" 2>/dev/null
grep -qx "ro.config.wallpaper=$WP" "$WORK/build.prop" ||
	{ echo "build.prop: ro.config.wallpaper is not $WP (scripts/debloat-gsi.sh)" >&2; exit 1; }
python3 -I "$ROOT/wallpaper/onebit.py" "$WORK/wallpaper.png"

cat >"$WORK/cmds" <<EOF
rm $WP
write $WORK/wallpaper.png $WP
sif $WP mode 0100644
sif $WP uid 0
sif $WP gid 0
ea_set -f $WORK/ctx-system $WP security.selinux
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
echo "$OUT: default wallpaper from wallpaper/onebit.py"
