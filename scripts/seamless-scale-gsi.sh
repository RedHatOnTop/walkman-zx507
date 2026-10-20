#!/usr/bin/env bash
# Keeps downscaled SystemUI's bars at full size after a seamless rotation (devlog 2026-10-19).
#
# services.jar gets compat-scale/SeamlessScaleFix.java: WindowState.finishSeamlessRotation puts
# the window's compat scale back after SeamlessRotator.finish resets its surface matrix. Its
# odex, vdex and art are replaced from gsi/odex-cache/services-<dex key>
# (scripts/services-odex.sh) when that exists and removed otherwise, since the ones in the image
# no longer match.
#
# Usage: scripts/seamless-scale-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BT="$ROOT/tools/build-tools-dl/x/android-14"
DEXLIB2="$ROOT/tools/dexlib2-dl/dexlib2-2.5.2.jar:$ROOT/tools/dexlib2-dl/guava-27.1-android.jar"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SVC=/system/framework/services.jar
SVC_OAT=/system/framework/oat/arm64/services

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

debugfs -R "dump $SVC $WORK/services.jar" "$OUT" 2>/dev/null
java -Xmx3g -cp "$DEXLIB2:$BT/lib/d8.jar" "$ROOT/compat-scale/SeamlessScaleFix.java" \
	"$WORK/services.jar" "$ROOT/compat-scale/ZxSeamlessScale.java" "$WORK/services-unaligned.jar"
"$BT/zipalign" -p -f 4 "$WORK/services-unaligned.jar" "$WORK/services-patched.jar"
KEY=$(env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/dex-key.py" "$WORK/services-patched.jar")
ODEX="$ROOT/gsi/odex-cache/services-$KEY"
if [ ! -s "$ODEX/services.odex" ]; then
	echo "no $ODEX: services.jar runs without odex (see scripts/services-odex.sh)" >&2
	ODEX=
fi

file() {
	cat <<EOF
write $1 $2
sif $2 mode 0100644
sif $2 uid 0
sif $2 gid 0
ea_set -f $WORK/ctx-system $2 security.selinux
EOF
}
{
	echo "rm $SVC"
	file "$WORK/services-patched.jar" $SVC
	for x in odex vdex art; do
		# An earlier step without a cached odex already took them out.
		if debugfs -R "stat $SVC_OAT.$x" "$OUT" 2>/dev/null | grep -q '^Inode:'; then
			echo "rm $SVC_OAT.$x"
		fi
		[ -z "$ODEX" ] || file "$ODEX/services.$x" "$SVC_OAT.$x"
	done
} >"$WORK/cmds"

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
echo "$OUT: compat scale kept through seamless rotation${ODEX:+ (+ odex)}"
