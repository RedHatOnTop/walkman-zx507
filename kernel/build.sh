#!/usr/bin/env bash
# Build the ZX507 kernel from Sony's GPL source with our patches.
#
# Runs on a plain x86_64 Linux host (meant for an aws-burst instance). Uses
# AOSP's gcc 4.9 aarch64 prebuilt, the compiler Sony shipped with, and pins the
# release string to the stock "4.14.78-g69dd21e" so the vendor's three modules
# (wlan, cxd3778gf_dnc_core, icx_nvp_emmc) still pass the vermagic check.
#
# Usage: kernel/build.sh <gpl_source.tgz> <out-dir>
# Leaves Image, vmlinux, Module.symvers, .config and build.log in <out-dir>.

set -euo pipefail
TGZ="$(realpath "$1")"
OUT="$(realpath -m "$2")"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Source paths end up in the Image (__FILE__ in WARN_ON); the published build uses a
# neutral KERNEL_WORK such as /build so the Image names no build machine.
WORK="${KERNEL_WORK:-$OUT/work}"
TC_URL=https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/pie-release.tar.gz
KSRC=vendor/nxp-opensource/kernel_imx
RELEASE_SUFFIX=-g69dd21e

# /proc/version reads the same for every build of this tree; Walkman Manager checks it
# after an install. Change the date with the patches.
export KBUILD_BUILD_USER=walkman-zx507 KBUILD_BUILD_HOST=kit KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="Thu Oct 15 00:00:00 UTC 2026"

mkdir -p "$OUT" "$WORK/tc"
echo "4ea368efdb62d167483d89e6ec60e2c3  $TGZ" | md5sum -c -

if [ ! -x "$WORK/tc/bin/aarch64-linux-android-gcc" ]; then
	curl -fsSL "$TC_URL" | tar -xz -C "$WORK/tc"
	# The gcc/g++ entry points are `#!/usr/bin/python` wrappers that exec
	# real-<name>; build hosts may only have python3.
	grep -l '^#!/usr/bin/python$' "$WORK"/tc/bin/* |
		xargs -r sed -i '1s|^#!/usr/bin/python$|#!/usr/bin/env python3|'
fi
# The Vivante GPU driver compiles in `hostname` (drivers/mxc/gpu-viv/Kbuild, -DHOST).
mkdir -p "$WORK/host-bin"
printf '#!/bin/sh\necho %s\n' "$KBUILD_BUILD_HOST" >"$WORK/host-bin/hostname"
chmod +x "$WORK/host-bin/hostname"
export PATH="$WORK/host-bin:$WORK/tc/bin:$PATH"
aarch64-linux-android-gcc --version | head -n 1

rm -rf "$WORK/src"
mkdir -p "$WORK/src"
tar -xzf "$TGZ" -C "$WORK/src" "./$KSRC"
cd "$WORK/src/$KSRC"
for p in "$HERE"/patches/*.patch; do
	echo "applying $(basename "$p")"
	git apply -p1 "$p"
done

make_k() {
	make ARCH=arm64 CROSS_COMPILE=aarch64-linux-android- \
		HOSTCFLAGS="-Wall -O2 -fomit-frame-pointer -std=gnu89 -fcommon" \
		O="$WORK/obj" "$@"
}
make_k android_dmp1_defconfig
scripts/config --file "$WORK/obj/.config" \
	--disable LOCALVERSION_AUTO --set-str LOCALVERSION "$RELEASE_SUFFIX" \
	--enable EXFAT_FS
make_k olddefconfig
make_k -j"$(nproc)" Image modules >"$OUT/build.log" 2>&1 || {
	tail -n 60 "$OUT/build.log"
	exit 1
}

cp "$WORK/obj/arch/arm64/boot/Image" "$WORK/obj/vmlinux" \
	"$WORK/obj/Module.symvers" "$WORK/obj/.config" "$OUT/"
cat "$WORK/obj/include/config/kernel.release"
