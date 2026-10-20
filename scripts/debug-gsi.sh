#!/usr/bin/env bash
# The debug tooling on a GSI image copy made by prepare-gsi.sh (local use only).
#
# - puts gsi-debug/init.sh in front of the real init as /init, with a static
#   busybox at /zx/busybox and an empty /zx/run for its tmpfs, and
#   gsi-debug/zxdbg.rc, which makes init wait while the wrapper hands USB over
# - makes the `kernel` SELinux domain permissive, so the wrapper's processes
#   keep working after init loads the policy
# - installs this host's adb key as /adb_keys (ADB_KEY, default ~/.android/adbkey.pub)
#
# Usage: [ADB_KEY=<adbkey.pub>] scripts/debug-gsi.sh <in.img> <out.img> <busybox-aarch64-static>

set -euo pipefail
IN="$1"
OUT="$2"
BUSYBOX="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB_KEY="${ADB_KEY:-$HOME/.android/adbkey.pub}"
PART_BYTES=3145728000 # system_b
[ -s "$ADB_KEY" ] || { echo "no adb public key at $ADB_KEY (set ADB_KEY)" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ctx() { printf '%s\0' "$1" >"$WORK/ctx-$2"; }
ctx u:object_r:init_exec:s0 init
ctx u:object_r:system_file:s0 system
ctx u:object_r:sepolicy_file:s0 sepolicy
ctx u:object_r:adb_keys_file:s0 adbkeys

cp --reflink=auto "$IN" "$OUT"
truncate -s "$PART_BYTES" "$OUT"
resize2fs "$OUT" >/dev/null

CIL=/system/etc/selinux/plat_sepolicy.cil
debugfs -R "dump $CIL $WORK/plat.cil" "$OUT" 2>/dev/null
grep -qx '(typepermissive kernel)' "$WORK/plat.cil" || printf '(typepermissive kernel)\n' >>"$WORK/plat.cil"

cat >"$WORK/cmds" <<EOF
mkdir /zx
sif /zx mode 040755
ea_set -f $WORK/ctx-system /zx security.selinux
mkdir /zx/run
sif /zx/run mode 040755
ea_set -f $WORK/ctx-system /zx/run security.selinux
write $BUSYBOX /zx/busybox
sif /zx/busybox mode 0100755
sif /zx/busybox uid 0
sif /zx/busybox gid 0
ea_set -f $WORK/ctx-system /zx/busybox security.selinux
rm /init
write $ROOT/gsi-debug/init.sh /init
sif /init mode 0100750
sif /init uid 0
sif /init gid 2000
ea_set -f $WORK/ctx-init /init security.selinux
rm $CIL
write $WORK/plat.cil $CIL
sif $CIL mode 0100644
sif $CIL uid 0
sif $CIL gid 0
ea_set -f $WORK/ctx-sepolicy $CIL security.selinux
write $ADB_KEY /adb_keys
sif /adb_keys mode 0100644
sif /adb_keys uid 0
sif /adb_keys gid 0
ea_set -f $WORK/ctx-adbkeys /adb_keys security.selinux
write $ROOT/gsi-debug/zxdbg.rc /system/etc/init/zxdbg.rc
sif /system/etc/init/zxdbg.rc mode 0100644
sif /system/etc/init/zxdbg.rc uid 0
sif /system/etc/init/zxdbg.rc gid 0
ea_set -f $WORK/ctx-system /system/etc/init/zxdbg.rc security.selinux
EOF
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
echo "$OUT: debug wrapper, permissive kernel domain, adb key"
