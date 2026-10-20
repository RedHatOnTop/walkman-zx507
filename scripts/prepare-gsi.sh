#!/usr/bin/env bash
# The first step on a GSI system image for the ZX507, debug or release build.
#
# - grows the copy and unshares its deduplicated blocks so it can be edited
# - with BOOTANIM=<zip>, installs that boot animation (the unit's own stock
#   /system/media/bootanimation.zip; never shipped, local builds only)
# - shrinks the result back to its minimum size
#
# Usage: [BOOTANIM=<zip>] scripts/prepare-gsi.sh <gsi.img> <out.img>

set -euo pipefail
SRC="$1"
OUT="$2"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

cp --reflink=auto "$SRC" "$OUT"
truncate -s "$PART_BYTES" "$OUT"
resize2fs "$OUT" >/dev/null
# e2fsck exits 1 when it changed the filesystem, which unsharing always does.
e2fsck -fy -E unshare_blocks "$OUT" >/dev/null || [ $? -eq 1 ]

if [ -n "${BOOTANIM:-}" ]; then
	cat >"$WORK/cmds" <<EOF
mkdir /system/media
sif /system/media mode 040755
ea_set -f $WORK/ctx-system /system/media security.selinux
write $BOOTANIM /system/media/bootanimation.zip
sif /system/media/bootanimation.zip mode 0100644
sif /system/media/bootanimation.zip uid 0
sif /system/media/bootanimation.zip gid 0
ea_set -f $WORK/ctx-system /system/media/bootanimation.zip security.selinux
EOF
	debugfs -w -f "$WORK/cmds" "$OUT" >"$WORK/debugfs.log" 2>&1
	if grep -vE '^(debugfs [0-9.]+ \(|debugfs: |Allocated inode: [0-9]+$|$)' "$WORK/debugfs.log" | grep -q .; then
		cat "$WORK/debugfs.log" >&2
		exit 1
	fi
fi

e2fsck -fn "$OUT" >/dev/null
resize2fs -M "$OUT" >/dev/null
blocks=$(dumpe2fs -h "$OUT" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2); print $2}')
truncate -s $((blocks * 4096)) "$OUT"
e2fsck -fn "$OUT" >/dev/null
echo "$OUT: $((blocks * 4096)) bytes"
