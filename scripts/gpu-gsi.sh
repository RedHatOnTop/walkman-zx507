#!/usr/bin/env bash
# GPU pipeline fixes on a GSI image copy (devlog 2026-10-15, 22:59-23:45):
#
# - The vendor Vivante GLES library waits for the GPU on every Skia vertex
#   upload because it ignores glBufferData(NULL). scripts/vivante-orphan.py
#   patches a copy taken from the unit's vendor image; the copy goes to
#   /system/etc/zx507 and gsi-init/zx507-gpu.rc + zx507-gpu.sh bind it over
#   /vendor/lib64/egl/libGLESv2_VIVANTE.so at post-fs. A/B by bind mount:
#   shade drag 41-54 -> 54 fps, shade close 51-56 -> 60, drawer open
#   49 / 56 -> 53 / 60 fps.
# - debug.sf.luma_sampling=0: the gesture-nav handle's 10 Hz SurfaceFlinger
#   readback, each one a GPU render SurfaceFlinger waits on. The black theme
#   leaves the handle nothing to adapt to. Missed vsyncs 10.5 -> 9.6 %.
#
# Usage: scripts/gpu-gsi.sh <in.img> <out.img> <vendor.img>
# <vendor.img> is the unit's 4.06.00 vendor image; the library is Sony/NXP's
# and only ever lands in the image, never in this repository.

set -euo pipefail
IN="$1"
OUT="$2"
VENDOR="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROPS="
debug.sf.luma_sampling=0
"
DIR=/system/etc/zx507
LIB=$DIR/libGLESv2_VIVANTE.so
RC=/system/etc/init/zx507-gpu.rc
SH=/system/bin/zx507-gpu.sh

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"
printf '%s\0' u:object_r:phhsu_exec:s0 >"$WORK/ctx-phhsu"
printf '%s\0' u:object_r:same_process_hal_file:s0 >"$WORK/ctx-sphal"

debugfs -R "dump /lib64/egl/libGLESv2_VIVANTE.so $WORK/vendor-gles.so" "$VENDOR" 2>/dev/null
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/vivante-orphan.py" \
	"$WORK/vendor-gles.so" "$WORK/gles.so"

debugfs -R "dump /system/build.prop $WORK/build.prop" "$OUT" 2>/dev/null
printf '\n# ZX507 GPU pipeline (scripts/gpu-gsi.sh)\n' >>"$WORK/build.prop"
for p in $PROPS; do
	grep -q "^${p%%=*}=" "$WORK/build.prop" && { echo "build.prop already sets ${p%%=*}" >&2; exit 1; }
	echo "$p" >>"$WORK/build.prop"
done
mode=$(debugfs -R "stat /system/build.prop" "$OUT" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p')

cat >"$WORK/cmds" <<CMDS
rm /system/build.prop
write $WORK/build.prop /system/build.prop
sif /system/build.prop mode 0100$mode
sif /system/build.prop uid 0
sif /system/build.prop gid 0
ea_set -f $WORK/ctx-system /system/build.prop security.selinux
mkdir $DIR
sif $DIR mode 040755
ea_set -f $WORK/ctx-system $DIR security.selinux
write $WORK/gles.so $LIB
sif $LIB mode 0100644
sif $LIB uid 0
sif $LIB gid 0
ea_set -f $WORK/ctx-sphal $LIB security.selinux
write $ROOT/gsi-init/zx507-gpu.rc $RC
sif $RC mode 0100644
sif $RC uid 0
sif $RC gid 0
ea_set -f $WORK/ctx-system $RC security.selinux
write $ROOT/gsi-init/zx507-gpu.sh $SH
sif $SH mode 0100755
sif $SH uid 0
sif $SH gid 2000
ea_set -f $WORK/ctx-phhsu $SH security.selinux
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
echo "$OUT: GPU pipeline fixes"
