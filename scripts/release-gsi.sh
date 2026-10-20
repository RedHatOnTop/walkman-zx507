#!/usr/bin/env bash
# What a release image changes from the GSI's userdebug defaults (devlog 2026-10-20). Takes an
# image without the debug tooling (prepare-gsi.sh, not debug-gsi.sh).
#
# - adb needs the owner's OK for each computer: TrebleDroid ships ro.adb.secure=0, which lets
#   any computer on the cable in without asking.
# - USB starts as file transfer (MTP), as on stock, instead of adb.
# - Without KEEP_SU=1 (the default) there is no root: ro.debuggable=0, so adbd cannot restart
#   as root, and TrebleDroid's su goes (/system/xbin/su, phh-su and its daemon). /system/xbin
#   holds only su; with it gone, rw-system.sh's bind mount of an empty su over it fails and
#   leaves nothing named su behind.
#
# Usage: [KEEP_SU=1] scripts/release-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

exists() { debugfs -R "stat $1" "$OUT" 2>/dev/null | grep -q '^Inode:'; }

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

for f in /zx /adb_keys /system/etc/init/zxdbg.rc; do
	! exists $f || { echo "$IN: has $f, a debug image (debug-gsi.sh)" >&2; exit 1; }
done

SU=(/system/xbin/su /system/bin/phh-su /system/etc/init/su.rc)
if [ -z "${KEEP_SU:-}" ]; then
	for f in "${SU[@]}"; do
		exists $f || { echo "$IN: no $f" >&2; exit 1; }
	done
fi

# Each file must change: a line already gone means the GSI is not the one these defaults
# were read from.
SED=(-e 's/^ro\.adb\.secure=0$/ro.adb.secure=1/' -e 's/^persist\.sys\.usb\.config=adb$/persist.sys.usb.config=mtp/')
[ -n "${KEEP_SU:-}" ] || SED+=(-e 's/^ro\.debuggable=1$/ro.debuggable=0/')
: >"$WORK/cmds"
for p in /system/build.prop /system/system_ext/etc/build.prop; do
	n=$(basename "$(dirname "$p")")
	debugfs -R "dump $p $WORK/$n.prop" "$OUT" 2>/dev/null
	sed "${SED[@]}" "$WORK/$n.prop" >"$WORK/$n.new"
	! cmp -s "$WORK/$n.prop" "$WORK/$n.new" || { echo "$IN: nothing to change in $p" >&2; exit 1; }
	mode=$(debugfs -R "stat $p" "$OUT" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p')
	cat >>"$WORK/cmds" <<EOF
rm $p
write $WORK/$n.new $p
sif $p mode 0100$mode
sif $p uid 0
sif $p gid 0
ea_set -f $WORK/ctx-system $p security.selinux
EOF
done
grep -qx 'ro.adb.secure=0' "$WORK/system.new" "$WORK/etc.new" && { echo "ro.adb.secure=0 left" >&2; exit 1; }
grep -qx 'persist.sys.usb.config=mtp' "$WORK/system.new" || { echo "no persist.sys.usb.config to change" >&2; exit 1; }
if [ -z "${KEEP_SU:-}" ]; then
	grep -qx 'ro.debuggable=0' "$WORK/system.new" || { echo "no ro.debuggable to change" >&2; exit 1; }
	for f in "${SU[@]}"; do
		echo "rm $f"
	done >>"$WORK/cmds"
	echo "rmdir /system/xbin" >>"$WORK/cmds"
fi

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
echo "$OUT: release defaults (adb asks, USB as MTP, $([ -n "${KEEP_SU:-}" ] && echo "su kept" || echo "no root"))"
