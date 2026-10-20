#!/usr/bin/env bash
# Copies one of our prebuilt binaries (scripts/fetch-tools.sh put it in tools/prebuilt/) after
# checking it against kit/prebuilt.sha256.
#
# Usage: scripts/prebuilt.sh <name> <dest>

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tools/prebuilt/$1"
[ -s "$SRC" ] || { echo "no $SRC (scripts/fetch-tools.sh)" >&2; exit 1; }
grep -q -x -F "$(sha256sum "$SRC" | cut -d' ' -f1)  $1" "$ROOT/kit/prebuilt.sha256" ||
	{ echo "$SRC is not the build in kit/prebuilt.sha256" >&2; exit 1; }
cp "$SRC" "$2"
