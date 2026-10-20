#!/usr/bin/env bash
# Replace the /init wrapper of a debug image (debug-gsi.sh) and its
# zxdbg.rc with the current gsi-debug/ files, without rebuilding the image
# from the GSI.
#
# Usage: scripts/refresh-debug-wrapper.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:init_exec:s0 >"$WORK/ctx-init"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"
RC=/system/etc/init/zxdbg.rc

debugfs -R "stat /zx/busybox" "$OUT" 2>/dev/null | grep -q '^Inode:' ||
	{ echo "$IN: no /zx/busybox, not a debug image" >&2; exit 1; }

cat >"$WORK/cmds" <<EOF
rm /init
write $ROOT/gsi-debug/init.sh /init
sif /init mode 0100750
sif /init uid 0
sif /init gid 2000
ea_set -f $WORK/ctx-init /init security.selinux
rm $RC
write $ROOT/gsi-debug/zxdbg.rc $RC
sif $RC mode 0100644
sif $RC uid 0
sif $RC gid 0
ea_set -f $WORK/ctx-system $RC security.selinux
EOF

debugfs -w -f "$WORK/cmds" "$OUT" >"$WORK/debugfs.log" 2>&1
if grep -vE '^(debugfs [0-9.]+ \(|debugfs: |Allocated inode: [0-9]+$|$)' "$WORK/debugfs.log" | grep -q .; then
	cat "$WORK/debugfs.log" >&2
	exit 1
fi
e2fsck -fn "$OUT" >/dev/null
echo "$OUT: /init and zxdbg.rc from gsi-debug/"
