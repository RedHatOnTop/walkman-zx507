#!/usr/bin/env bash
# Going back to stock: the four partitions of Sony's firmware, out of the owner's UPG with the
# unit's key, as an install set for slot b. The "Back to stock" section of docs/install.md in
# one run, and the entry point walkman-manager's Firmware Studio drives for it.
#
# <out-dir> gets:
#   vbmeta.img, boot.img, system.img, vendor.img
#                 the stock images, linked from <stock-dir> (copied where links cannot go)
#   install.json  install-json.py --stock: the four writes to slot b and the stock read-back
# <stock-dir> is the one make-install.sh keeps; an earlier build leaves nothing to decrypt.
#
# Progress as make-install.sh: "== total <n>" first, then "== <i> <step>" as each step starts.
#
# Usage: scripts/make-restore.sh <file.UPG> <icx_nvp.cfg> <stock-dir> <out-dir>

set -euo pipefail
export LC_ALL=C.UTF-8
UPG="$1"
KEYFILE="$2"
STOCK="$3"
OUT="$4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for f in "$UPG" "$KEYFILE"; do
	[ -f "$f" ] || { echo "no $f" >&2; exit 1; }
done
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "$OUT is not empty" >&2; exit 1; }
mkdir -p "$OUT"

echo "== total 2"
echo "== 1 stock"
"$ROOT/scripts/unpack-stock.sh" "$UPG" "$KEYFILE" "$STOCK"
PINS="$(grep -l -F -- "SHA-224 $(dd if="$UPG" bs=1 skip=4 count=56 2>/dev/null)" "$ROOT"/kit/stock-*.sha256)"

echo "== 2 install"
for p in vbmeta boot system vendor; do
	ln "$STOCK/$p.img" "$OUT/$p.img" 2>/dev/null || cp --reflink=auto "$STOCK/$p.img" "$OUT/$p.img"
done
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$ROOT/scripts/install-json.py" \
	--stock "$OUT" "$PINS" >"$OUT/install.json"
cat "$OUT/install.json"
