#!/usr/bin/env bash
# Legacy Korean tags read as CP949 on a GSI image copy (devlog 2026-10-17).
# libzx507tagcharset.so (tag-charset/; prebuilt, or with KIT_FROM_SOURCE=1
# built against this image) goes to /system/lib and /system/lib64,
# mediaserver (where MediaProvider's metadata retriever decodes tags) gets it
# as its first DT_NEEDED, and build.prop makes persist.sys.tagloc=ko the
# default. Any other value of the property leaves libmedia's decoding as it
# was. LD_PRELOAD does not work there: init's domain transition to
# mediaserver sets AT_SECURE.
#
# W.music reads tags with its own parser, decoding them in the charset of the
# UI language (CP1252 for English). tag-charset/WmTagCharsetFix.java adds
# tag-charset/ZxTagCharset.java, the same rule under the same property, to
# its SpMetaParser; the APK is re-signed with the platform test key, as
# scripts/add-sony-apps.sh did.
#
# Usage: scripts/tag-charset-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BT="$ROOT/tools/build-tools-dl/x/android-14"
KEYS="$ROOT/tools/aosp-testkeys"
DEXLIB2="$ROOT/tools/dexlib2-dl/dexlib2-2.5.2.jar:$ROOT/tools/dexlib2-dl/guava-27.1-android.jar"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MS=/system/bin/mediaserver
MS_SHA256=91e082092f3031d7d12fec2e45c243c657ef8d0c99338149229ce23cf7c7add2
LIB=libzx507tagcharset.so
WM=/system/priv-app/HighResMediaPlayerApp/HighResMediaPlayerApp.apk

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"
printf '%s\0' u:object_r:system_lib_file:s0 >"$WORK/ctx-lib"
printf '%s\0' u:object_r:mediaserver_exec:s0 >"$WORK/ctx-ms"

if [ -n "${KIT_FROM_SOURCE:-}" ]; then
	"$ROOT/tag-charset/build.sh" "$IN" "$WORK/build"
else
	mkdir -p "$WORK/build/lib" "$WORK/build/lib64"
	"$ROOT/scripts/prebuilt.sh" libzx507tagcharset-arm.so "$WORK/build/lib/$LIB"
	"$ROOT/scripts/prebuilt.sh" libzx507tagcharset-arm64.so "$WORK/build/lib64/$LIB"
fi

# libmedia is not among mediaserver's own DT_NEEDED, so a library first in
# that list comes before it in the linker's search order and its
# detectAndConvert() is the one libmediaplayerservice binds to.
debugfs -R "dump $MS $WORK/mediaserver" "$OUT" 2>/dev/null
[ "$(sha256sum "$WORK/mediaserver" | cut -d' ' -f1)" = $MS_SHA256 ] ||
	{ echo "$MS: unexpected sha256" >&2; exit 1; }
patchelf --add-needed $LIB "$WORK/mediaserver"
[ "$(patchelf --print-needed "$WORK/mediaserver" | head -1)" = $LIB ] ||
	{ echo "$MS: $LIB is not the first DT_NEEDED" >&2; exit 1; }

debugfs -R "dump $WM $WORK/wm.apk" "$OUT" 2>/dev/null
[ -s "$WORK/wm.apk" ] || { echo "$WM: not in $IN" >&2; exit 1; }
java -Xmx3g -cp "$DEXLIB2:$BT/lib/d8.jar" "$ROOT/tag-charset/WmTagCharsetFix.java" \
	"$WORK/wm.apk" "$ROOT/tag-charset/ZxTagCharset.java" "$WORK/wm-unsigned.apk"
"$BT/zipalign" -p -f 4 "$WORK/wm-unsigned.apk" "$WORK/wm-aligned.apk"
"$BT/apksigner" sign --key "$KEYS/platform.pk8" --cert "$KEYS/platform.x509.pem" \
	--out "$WORK/wm-patched.apk" "$WORK/wm-aligned.apk"
"$BT/apksigner" verify "$WORK/wm-patched.apk"

debugfs -R "dump /system/build.prop $WORK/build.prop" "$OUT" 2>/dev/null
! grep -q '^persist\.sys\.tagloc=' "$WORK/build.prop" ||
	{ echo "build.prop: persist.sys.tagloc already set" >&2; exit 1; }
printf '\n# legacy (ID3v1 / Latin-1) tags are CP949 Korean: libzx507tagcharset.so\npersist.sys.tagloc=ko\n' \
	>>"$WORK/build.prop"
bmode=$(debugfs -R "stat /system/build.prop" "$OUT" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p')

file() {
	cat <<EOF
write $1 $2
sif $2 mode 0100${4:-644}
sif $2 uid 0
sif $2 gid ${5:-0}
ea_set -f $WORK/ctx-${3:-system} $2 security.selinux
EOF
}
{
	for abi in lib lib64; do
		file "$WORK/build/$abi/$LIB" /system/$abi/$LIB lib
	done
	echo "rm $MS"
	file "$WORK/mediaserver" $MS ms 755 2000
	echo "rm $WM"
	file "$WORK/wm-patched.apk" $WM
	echo "rm /system/build.prop"
	file "$WORK/build.prop" /system/build.prop system "$bmode"
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
echo "$OUT: legacy tags read as CP949 ($LIB in mediaserver, ZxTagCharset in W.music, persist.sys.tagloc=ko)"
