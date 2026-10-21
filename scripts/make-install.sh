#!/usr/bin/env bash
# Everything the ZX507 install takes, from the owner's own files: Sony's UPG with the unit's
# key, TrebleDroid's GSI and a kernel Image from kernel/build.sh. The hand steps of
# docs/install.md sections 1 to 3 in one run, and the entry point walkman-manager's Firmware
# Studio drives.
#
# <out-dir> gets:
#   system.img    build-image.sh's result (RELEASE and KEEP_SU as there)
#   boot.img      the stock boot image with the kernel swapped in (kernel/repack-boot.py)
#   vbmeta.img    the stock vbmeta with verity and verification off
#   manifest.tsv  image-manifest.py of system.img
#   install.json  what goes to which partition, the hashes, and what to read back after boot
# <stock-dir> keeps the four stock partitions between runs (unpack-stock.sh); they are also
# what going back to stock takes (make-restore.sh).
#
# Progress: "== total <n>" first, then one "== <i> <step>" line as each step starts. Every
# other line is a step's own output.
#
# Usage: [RELEASE=1 [KEEP_SU=1]] [ADB_KEY=<adbkey.pub>] [ANDROID_SDK_LICENSE=accepted] \
#        [KIT_FROM_SOURCE=1 [NDK=<dir>] [ANDROID_SDK=<dir>]] \
#            scripts/make-install.sh <file.UPG> <icx_nvp.cfg> <gsi.img|gsi.img.xz> \
#            <kernel-Image> <stock-dir> <out-dir>
# ANDROID_SDK_LICENSE and KIT_FROM_SOURCE as in scripts/fetch-tools.sh.

set -euo pipefail
# Glob and sort order decide entry order in generated XML and APKs; one locale, same bytes.
export LC_ALL=C.UTF-8
UPG="$1"
KEYFILE="$2"
GSI_IN="$3"
KERNEL="$4"
STOCK="$5"
OUT="$6"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NDK="${NDK:-$HOME/.cache/android-ndk/android-ndk-r27c}"
ANDROID_SDK="${ANDROID_SDK:-$HOME/Android/sdk}"
export NDK ANDROID_SDK
RELEASE_STRING=4.14.78-g69dd21e

for f in "$UPG" "$KEYFILE" "$GSI_IN" "$KERNEL"; do
	[ -f "$f" ] || { echo "no $f" >&2; exit 1; }
done
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "$OUT is not empty" >&2; exit 1; }
mkdir -p "$OUT"

total=$((3 + $("$ROOT/scripts/build-image.sh" --count) + 3))
echo "== total $total"
i=0
top() {
	i=$((i + 1))
	echo "== $i $1"
}

top tools
if [ -n "${KIT_FROM_SOURCE:-}" ]; then
	for need in "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang" \
		"$ANDROID_SDK/build-tools/35.0.0/d8" "$ANDROID_SDK/platforms/android-35/android.jar"; do
		[ -e "$need" ] || { echo "missing $need (NDK r27c as NDK=, SDK build-tools 35.0.0 and android-35 as ANDROID_SDK=)" >&2; exit 1; }
	done
fi
"$ROOT/scripts/fetch-tools.sh" --tools-only

top stock
"$ROOT/scripts/unpack-stock.sh" "$UPG" "$KEYFILE" "$STOCK"
PINS="$(grep -l -F -- "SHA-224 $(dd if="$UPG" bs=1 skip=4 count=56 2>/dev/null)" "$ROOT"/kit/stock-*.sha256)"

top gsi
GSI="$OUT/.gsi.img"
trap 'rm -f "$GSI"' EXIT
case "$(head -c 6 "$GSI_IN" | od -An -tx1 | tr -d ' ')" in
fd377a585a00) xz -dc -T0 "$GSI_IN" >"$GSI" ;;
*) cp --reflink=auto "$GSI_IN" "$GSI" ;;
esac
(cd "$OUT" && sed 's/  .*/  .gsi.img/' "$ROOT/kit/gsi.sha256" | sha256sum -c)

# build-image.sh numbers its own steps from 1; they are steps 4.. here.
RELEASE="${RELEASE:-}" KEEP_SU="${KEEP_SU:-}" "$ROOT/scripts/build-image.sh" \
	"$GSI" "$STOCK/system.img" "$STOCK/vendor.img" "$OUT/system.img" |
	while IFS= read -r line; do
		if [[ "$line" =~ ^==\ ([0-9]+)\ (.*)$ ]]; then
			echo "== $((3 + BASH_REMATCH[1])) ${BASH_REMATCH[2]}"
		else
			printf '%s\n' "$line"
		fi
	done
i=$((i + $("$ROOT/scripts/build-image.sh" --count)))
rm -f "$GSI"

top boot
# An arm64 Image carries "ARM\x64" at byte 56, and the vendor's modules load only into the
# stock release string.
[ "$(dd if="$KERNEL" bs=1 skip=56 count=4 2>/dev/null | od -An -tx1 | tr -d ' ')" = 41524d64 ] ||
	{ echo "$KERNEL is not an arm64 kernel Image" >&2; exit 1; }
grep -a -q -F "Linux version $RELEASE_STRING " "$KERNEL" ||
	{ echo "$KERNEL is not a $RELEASE_STRING kernel (kernel/build.sh pins that release)" >&2; exit 1; }
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/kernel/repack-boot.py" \
	"$STOCK/boot.img" "$KERNEL" "$OUT/boot.img"
# Verity and verification off in the image itself (AvbVBMetaImageHeader.flags, big-endian at
# 120): fastboot 37.0.0 fails its own --disable-verity rewrite when the image is smaller than
# the partition ("Failed to find AVB_MAGIC at offset: 0").
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I - "$STOCK/vbmeta.img" "$OUT/vbmeta.img" <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
if data[:4] != b"AVB0":
    sys.exit(f"{sys.argv[1]}: no AVB0 magic")
flags = struct.unpack_from(">I", data, 120)[0]
struct.pack_into(">I", data, 120, flags | 0x3)
open(sys.argv[2], "wb").write(data)
PY

top manifest
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/image-manifest.py" \
	"$OUT/system.img" >"$OUT/manifest.tsv"
wc -l <"$OUT/manifest.tsv"

top install
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/install-json.py" \
	"$OUT" "$KERNEL" "$PINS" >"$OUT/install.json"
cat "$OUT/install.json"
