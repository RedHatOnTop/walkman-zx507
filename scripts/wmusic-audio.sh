#!/usr/bin/env bash
# Let W.music play on the Android 13 GSI: install libwmtrackshim.so and point
# the image's own libspmedia_walkman.so at it (scripts/patch-spmedia.py,
# audio-shim/). Without this the player dies with SIGSEGV in
# NativeAudioTrackSinkFilter::setup() -> RefBase::incStrong on its first track.
#
# Run on an image that already has the Sony apps (add-sony-apps.sh).
#
# Usage: scripts/wmusic-audio.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SP=/system/lib64/libspmedia_walkman.so
SHIM=/system/lib64/libwmtrackshim.so

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_lib_file:s0 >"$WORK/ctx-lib"

if [ -n "${KIT_FROM_SOURCE:-}" ]; then
	"$ROOT/audio-shim/build.sh" "$OUT" "$WORK/libwmtrackshim.so"
else
	"$ROOT/scripts/prebuilt.sh" libwmtrackshim.so "$WORK/libwmtrackshim.so"
fi
debugfs -R "dump $SP $WORK/libspmedia_walkman.so" "$OUT" 2>/dev/null
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/patch-spmedia.py" \
	"$WORK/libspmedia_walkman.so" "$WORK/libspmedia_walkman.patched.so"

{
	echo "rm $SP"
	echo "write $WORK/libspmedia_walkman.patched.so $SP"
	echo "write $WORK/libwmtrackshim.so $SHIM"
	for f in $SP $SHIM; do
		cat <<EOF
sif $f mode 0100644
sif $f uid 0
sif $f gid 0
ea_set -f $WORK/ctx-lib $f security.selinux
EOF
	done
} >"$WORK/cmds"

debugfs -w -f "$WORK/cmds" "$OUT" >"$WORK/debugfs.log" 2>&1
if grep -vE '^(debugfs [0-9.]+ \(|debugfs: |Allocated inode: [0-9]+$|$)' "$WORK/debugfs.log" | grep -q .; then
	cat "$WORK/debugfs.log" >&2
	exit 1
fi
e2fsck -fn "$OUT" >/dev/null
echo "$OUT: W.music AudioTrack shim installed"
