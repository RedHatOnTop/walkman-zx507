#!/usr/bin/env bash
# Build libwmtrackshim.so with the NDK, linked against the GSI's own
# libaudioclient, libutils and libc++ (taken from the image, so the imported
# symbols are exactly the ones the unit will resolve).
#
# Usage: audio-shim/build.sh <gsi-system.img> <out.so>
# NDK defaults to ~/.cache/android-ndk/android-ndk-r27c; override with NDK=.

set -euo pipefail
IMG="$1"
OUT="$2"
NDK="${NDK:-$HOME/.cache/android-ndk/android-ndk-r27c}"
CXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang++"
SRC="$(cd "$(dirname "$0")" && pwd)/wmtrackshim.cpp"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for l in libaudioclient.so libutils.so libc++.so; do
	debugfs -R "dump /system/lib64/$l $WORK/$l" "$IMG" 2>/dev/null
	[ -s "$WORK/$l" ] || { echo "missing /system/lib64/$l in $IMG" >&2; exit 1; }
done

"$CXX" -shared -fPIC -O2 -Wall -Wextra -Werror -std=c++17 \
	-fno-rtti -fno-exceptions -fno-sized-deallocation -nostdlib++ \
	-Wl,-soname,libwmtrackshim.so -Wl,--no-undefined -Wl,-z,defs \
	"$SRC" "$WORK/libaudioclient.so" "$WORK/libutils.so" "$WORK/libc++.so" -llog \
	-o "$OUT"
