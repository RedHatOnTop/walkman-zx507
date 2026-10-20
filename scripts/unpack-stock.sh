#!/usr/bin/env bash
# The four stock partitions the build takes from Sony's firmware: decrypts the owner's UPG with
# the unit's key (decrypt-upg.sh), extracts boot, vbmeta, system and vendor from its payload
# (extract-partition.py) and checks each against kit/stock-<firmware>-<series>.sha256.
#
# <stock-dir> is kept between builds: when it already holds the four images with the pinned
# hashes, nothing is decrypted again.
#
# Usage: scripts/unpack-stock.sh <file.UPG> <icx_nvp.cfg> <stock-dir>

set -euo pipefail
UPG="$1"
KEYFILE="$2"
DIR="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARTS="boot vbmeta system vendor"

# The pins file whose first line names the payload digest in the UPG's header, so a renamed
# copy of the firmware is still found.
SHA224="$(dd if="$UPG" bs=1 skip=4 count=56 2>/dev/null)"
PINS="$(grep -l -F -- "SHA-224 $SHA224" "$ROOT"/kit/stock-*.sha256 2>/dev/null | head -n 1 || true)"
[ -n "$PINS" ] || {
	echo "$UPG: this kit knows no firmware with payload SHA-224 '$SHA224' (it knows $(cd "$ROOT/kit" && echo stock-*.sha256))" >&2
	exit 1
}
echo "$(basename "$UPG"): $(head -n 1 "$PINS" | sed 's/^# //; s/\. UPG payload.*//')"

pinned() {
	(cd "$DIR" && sha256sum --quiet -c "$PINS") >/dev/null 2>&1
}
mkdir -p "$DIR"
if pinned; then
	echo "$DIR: the stock images are already here"
	exit 0
fi

WORK="$(mktemp -d "$DIR/.unpack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
"$ROOT/scripts/decrypt-upg.sh" "$UPG" -k "$KEYFILE" -o "$WORK/ota.zip"
for p in $PARTS; do
	env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/extract-partition.py" \
		"$WORK/ota.zip" --extract "$p" -o "$WORK/$p.img"
done
(cd "$WORK" && sha256sum -c "$PINS")
for p in $PARTS; do
	mv "$WORK/$p.img" "$DIR/$p.img"
done
echo "$DIR: $PARTS"
