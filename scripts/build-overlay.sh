#!/usr/bin/env bash
# Build and platform-sign a framework RRO from gsi-overlays/<name>.
#
# The A13 GSI is signed with the AOSP test keys, so the overlay is signed with
# the public AOSP platform key (tools/aosp-testkeys, from build/make
# target/product/security at android13-release). <framework-res.apk> is the
# unit's /system/framework/framework-res.apk, used only to link against.
#
# Usage: scripts/build-overlay.sh <name> <framework-res.apk> <out.apk>

set -euo pipefail
NAME="$1"
FW="$2"
OUT="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BT="$ROOT/tools/build-tools-dl/x/android-14"
KEYS="$ROOT/tools/aosp-testkeys"
SRC="$ROOT/gsi-overlays/$NAME"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$BT/aapt2" compile --dir "$SRC/res" -o "$WORK/res.zip"
"$BT/aapt2" link -I "$FW" --manifest "$SRC/AndroidManifest.xml" \
	--min-sdk-version 33 --target-sdk-version 33 -o "$WORK/unsigned.apk" "$WORK/res.zip"
"$BT/zipalign" -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$BT/apksigner" sign --key "$KEYS/platform.pk8" --cert "$KEYS/platform.x509.pem" \
	--out "$OUT" "$WORK/aligned.apk"
"$BT/apksigner" verify --print-certs "$OUT" | grep -m1 'SHA-256'
