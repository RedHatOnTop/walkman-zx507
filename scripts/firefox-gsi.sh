#!/usr/bin/env bash
# Firefox in place of AOSP's WebView test shell on a GSI image copy (devlog 2026-10-19).
#
# The user wants no Chrome-family browser on the unit. org.chromium.webview_shell
# (/system/product/app/Browser2, "WebView Browser Tester") goes; Mozilla's own Firefox APK, as
# signed by Mozilla, becomes an ordinary system app, so Aurora Store can update it. Its
# libraries are stored compressed with extractNativeLibs=true, which a system app never gets
# extracted, so they go next to it in lib/arm64. The system WebView (com.android.webview) stays:
# apps that render web pages need it.
#
# The APK is downloaded once into tools/firefox-dl/ and checked by sha256 and by Mozilla's
# release signing certificate.
#
# Usage: scripts/firefox-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BT="$ROOT/tools/build-tools-dl/x/android-14"
DL="$ROOT/tools/firefox-dl"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VER=158.0
URL=https://archive.mozilla.org/pub/fenix/releases/$VER/android/fenix-$VER-android-arm64-v8a/fenix-$VER.multi.android-arm64-v8a.apk
SHA=4e57f3d92b5f77feab700d454e8efb5030279855a2bae7db1a14521ac60df466
MOZILLA_CERT=a78b62a5165b4494b2fead9e76a280d22d937fee6251aece599446b2ea319b04
APP=/system/app/Firefox
SHELL_APP=/system/product/app/Browser2

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

mkdir -p "$DL"
APK="$DL/$(basename "$URL")"
[ -s "$APK" ] || curl -sSfL -o "$APK" "$URL"
[ "$(sha256sum "$APK" | cut -d' ' -f1)" = $SHA ] || { echo "$APK: unexpected sha256" >&2; exit 1; }
"$BT/apksigner" verify --print-certs "$APK" 2>/dev/null |
	grep -qx "Signer #1 certificate SHA-256 digest: $MOZILLA_CERT" ||
	{ echo "$APK: not signed with Mozilla's release key" >&2; exit 1; }
if debugfs -R "stat $APP" "$OUT" 2>/dev/null | grep -q '^Inode:'; then
	echo "$IN: $APP already exists" >&2
	exit 1
fi
for f in $SHELL_APP/Browser2.apk $SHELL_APP/oat/arm64/Browser2.odex $SHELL_APP/oat/arm64/Browser2.vdex; do
	debugfs -R "stat $f" "$OUT" 2>/dev/null | grep -q '^Inode:' || { echo "$IN: no $f" >&2; exit 1; }
done

mkdir "$WORK/lib"
unzip -q -j "$APK" 'lib/arm64-v8a/*.so' -d "$WORK/lib"

dir() {
	cat <<EOF
mkdir $1
sif $1 mode 040755
ea_set -f $WORK/ctx-system $1 security.selinux
EOF
}
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
	echo "rm $SHELL_APP/oat/arm64/Browser2.odex"
	echo "rm $SHELL_APP/oat/arm64/Browser2.vdex"
	echo "rmdir $SHELL_APP/oat/arm64"
	echo "rmdir $SHELL_APP/oat"
	echo "rm $SHELL_APP/Browser2.apk"
	echo "rmdir $SHELL_APP"
	dir $APP
	file "$APK" $APP/Firefox.apk
	dir $APP/lib
	dir $APP/lib/arm64
	for so in "$WORK"/lib/*.so; do
		file "$so" "$APP/lib/arm64/$(basename "$so")"
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
echo "$OUT: Firefox $VER in $APP, WebView test shell gone"
