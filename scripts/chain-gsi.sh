#!/usr/bin/env bash
# Runs image steps one after another, each a scripts/<step>-gsi.sh taking <in.img> <out.img>.
# The images in between go to a scratch directory next to <out.img>, on the same filesystem so
# the steps' copies stay reflinks, and are gone when it finishes.
#
# Usage: scripts/chain-gsi.sh <in.img> <out.img> <step>...
#   e.g. scripts/chain-gsi.sh gsi/system-td-zxdbg19-full.img gsi/system-td-zxdbg24-full.img \
#            microg seamless-scale identity wallpaper

set -euo pipefail
IN="$1"
OUT="$2"
shift 2
[ $# -gt 0 ] || { echo "no steps" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "$(dirname "$OUT")/.chain.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cur="$IN"
n=0
for step in "$@"; do
	n=$((n + 1))
	"$ROOT/scripts/$step-gsi.sh" "$cur" "$WORK/$n-$step.img"
	cur="$WORK/$n-$step.img"
done
mv "$cur" "$OUT"
