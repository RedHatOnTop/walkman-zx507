#!/usr/bin/env bash
# The kernel as published: Image plus its complete corresponding source (GPL-2.0).
#
# Usage: kernel/release.sh <gpl_source.tgz> <out-dir>
# Needs a writable /build (the tree's path is compiled into the Image). Leaves in <out-dir>:
#   Image                                    what Walkman Manager downloads
#   zx507-kernel-<release>-source.tar.xz     the patched tree, .config, patches, build.sh
#   SHA256SUMS
# vmlinux, Module.symvers and build.log from kernel/build.sh stay beside them.

set -euo pipefail
TGZ="$(realpath "$1")"
OUT="$(realpath -m "$2")"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD=/build
KSRC="$BUILD/src/vendor/nxp-opensource/kernel_imx"
STAMP="$(sed -n 's/^export KBUILD_BUILD_TIMESTAMP="\(.*\)"$/\1/p' "$HERE/build.sh")"

[ -d "$BUILD" ] && [ -w "$BUILD" ] || { echo "release.sh: $BUILD must exist and be writable" >&2; exit 1; }
mkdir -p "$OUT"
KERNEL_WORK="$BUILD" bash "$HERE/build.sh" "$TGZ" "$OUT" >"$OUT.release.log" 2>&1 || {
	tail -n 40 "$OUT.release.log" >&2
	exit 1
}
RELEASE="$(cat "$BUILD/obj/include/config/kernel.release")"
NAME="zx507-kernel-$RELEASE-source"
STAGE="$BUILD/$NAME"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$KSRC" "$STAGE/kernel_imx"
cp "$BUILD/obj/.config" "$STAGE/config"
cp -a "$HERE/patches" "$STAGE/patches"
cp "$HERE/build.sh" "$STAGE/build.sh"
cat >"$STAGE/README" <<EOF
Linux $RELEASE for the Sony NW-ZX500 series, as used by walkman-zx507.

kernel_imx/  Sony's GPL source release of 2021-10-22 (gpl_source.tgz, MD5
             4ea368efdb62d167483d89e6ec60e2c3, vendor/nxp-opensource/kernel_imx), with the
             patches in patches/ applied. The kernel's own COPYING applies.
config       the .config the published Image was built with.
build.sh     the script that built it from gpl_source.tgz.

To build the same Image: put kernel_imx/ at $KSRC (the path is
compiled in), have AOSP's aarch64-linux-android-4.9 gcc on PATH
(platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9, branch pie-release) and,
first on PATH, a \`hostname\` that prints "kit" (the GPU driver compiles the host name in), then

  export KBUILD_BUILD_USER=walkman-zx507 KBUILD_BUILD_HOST=kit KBUILD_BUILD_VERSION=1
  export KBUILD_BUILD_TIMESTAMP="$STAMP"
  mkdir -p $BUILD/obj && cp config $BUILD/obj/.config
  make -C $KSRC ARCH=arm64 CROSS_COMPILE=aarch64-linux-android- \\
    HOSTCFLAGS="-Wall -O2 -fomit-frame-pointer -std=gnu89 -fcommon" O=$BUILD/obj Image
EOF
tar -C "$BUILD" -cf - "$NAME" | xz -T0 -6 >"$OUT/$NAME.tar.xz"
rm -rf "$STAGE"
(cd "$OUT" && sha256sum Image "$NAME.tar.xz" >SHA256SUMS && cat SHA256SUMS)
grep -a -o -m1 'Linux version [[:print:]]*' "$OUT/Image"
