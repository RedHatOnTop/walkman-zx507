#!/usr/bin/env bash
# Our own binaries that go into the image, built from this repository against the pinned GSI:
# the set scripts/fetch-tools.sh downloads (kit/prebuilt.sha256), so an owner needs neither
# the NDK nor the SDK's build-tools 35. Built from the bare GSI they are the bytes the kit's
# steps build in place (a Studio build's manifest, 2026-10-20).
#
# Needs the NDK r27c (NDK=), the SDK's build-tools 35.0.0 and android-35 (ANDROID_SDK=) and
# the AOSP test keys from scripts/fetch-tools.sh.
#
# Usage: scripts/build-prebuilt.sh <gsi.img> <out-dir>

set -euo pipefail
GSI="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ "$(sha256sum "$GSI" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$ROOT/kit/gsi.sha256")" ] ||
	{ echo "$GSI is not the GSI in kit/gsi.sha256" >&2; exit 1; }
mkdir -p "$OUT"
"$ROOT/audio-shim/build.sh" "$GSI" "$OUT/libwmtrackshim.so"
"$ROOT/tag-charset/build.sh" "$GSI" "$WORK/tc"
cp "$WORK/tc/lib/libzx507tagcharset.so" "$OUT/libzx507tagcharset-arm.so"
cp "$WORK/tc/lib64/libzx507tagcharset.so" "$OUT/libzx507tagcharset-arm64.so"
"$ROOT/apps/volumedial/build.sh" "$OUT/ZX507VolumeDial.apk" >/dev/null
(cd "$OUT" && cut -d' ' -f3 "$ROOT/kit/prebuilt.sha256" | xargs sha256sum >SHA256SUMS && cat SHA256SUMS)
if cmp -s "$OUT/SHA256SUMS" "$ROOT/kit/prebuilt.sha256"; then
	echo "same as kit/prebuilt.sha256"
else
	echo "differs from kit/prebuilt.sha256" >&2
fi
