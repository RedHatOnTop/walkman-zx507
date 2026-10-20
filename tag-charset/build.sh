#!/usr/bin/env bash
# Build libzx507tagcharset.so and tagcharset-test for arm and arm64 with the
# NDK, linked against the GSI's own libmedia and, from its i18n APEX,
# libandroidicu, so the imported symbols are exactly the ones the unit will
# resolve.
#
# Usage: tag-charset/build.sh <gsi-system.img> <out-dir>
# Writes <out-dir>/{lib,lib64}/libzx507tagcharset.so and
# <out-dir>/tagcharset-test-{lib,lib64}.
# NDK defaults to ~/.cache/android-ndk/android-ndk-r27c; override with NDK=.

set -euo pipefail
IMG="$1"
OUT="$2"
NDK="${NDK:-$HOME/.cache/android-ndk/android-ndk-r27c}"
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

debugfs -R "dump /system/apex/com.android.i18n.apex $WORK/i18n.apex" "$IMG" 2>/dev/null
unzip -q -p "$WORK/i18n.apex" apex_payload.img >"$WORK/i18n.img"
for abi in lib lib64; do
	case $abi in
	lib) CC="$BIN/armv7a-linux-androideabi33-clang" ;;
	lib64) CC="$BIN/aarch64-linux-android33-clang" ;;
	esac
	mkdir -p "$WORK/$abi" "$OUT/$abi"
	debugfs -R "dump /system/$abi/libmedia.so $WORK/$abi/libmedia.so" "$IMG" 2>/dev/null
	debugfs -R "dump /$abi/libandroidicu.so $WORK/$abi/libandroidicu.so" "$WORK/i18n.img" 2>/dev/null
	for l in libmedia.so libandroidicu.so; do
		[ -s "$WORK/$abi/$l" ] || { echo "missing $abi/$l in $IMG" >&2; exit 1; }
	done
	"$CC++" -shared -fPIC -O2 -Wall -Wextra -Werror -std=c++17 -fvisibility=hidden \
		-fno-rtti -fno-exceptions -nostdlib++ \
		-Wl,-soname,libzx507tagcharset.so -Wl,--no-undefined -Wl,-z,defs \
		"$DIR/zx507tagcharset.cpp" "$WORK/$abi/libmedia.so" "$WORK/$abi/libandroidicu.so" \
		-llog -ldl -o "$OUT/$abi/libzx507tagcharset.so"
	"$CC" -O2 -Wall -Wextra -Werror -std=c11 -Wl,--allow-shlib-undefined \
		"$DIR/tagcharset-test.c" "$WORK/$abi/libmedia.so" -o "$OUT/tagcharset-test-$abi"
done
