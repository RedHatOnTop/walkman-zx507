#!/usr/bin/env bash
# Downloads what scripts/build-image.sh takes from outside this repository and the unit, each
# pinned by sha256: TrebleDroid's GSI into gsi/, and into tools/ the AOSP platform test key,
# build-tools 34, dexlib2 with guava, Debian's static arm64 busybox for the debug wrapper and
# Debian's static qemu-aarch64 for odex-gsi.sh.
# Into tools/prebuilt/ our own binaries from this repository's release (kit/prebuilt.sha256,
# scripts/build-prebuilt.sh), unless KIT_FROM_SOURCE=1 has the steps build them, which takes
# the NDK r27c (NDK=) and the SDK's build-tools 35.0.0 and android-35 (ANDROID_SDK=).
# Firefox and microG are fetched by their own steps. Files already there are checked, not
# fetched again.
#
# Google's build-tools come under the Android SDK License Agreement; they are downloaded only
# with ANDROID_SDK_LICENSE=accepted.
#
# Usage: scripts/fetch-tools.sh [--tools-only]    (--tools-only: everything but the GSI)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/tools"
AOSP=https://android.googlesource.com/platform/build/+/refs/heads/android13-release/target/product/security
MAVEN=https://repo1.maven.org/maven2
PREBUILT=https://github.com/RedHatOnTop/walkman-zx507/releases/download/prebuilt-2
GSI_TOO=1
[ "${1:-}" != --tools-only ] || GSI_TOO=

check() {
	[ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ] || { echo "$1: unexpected sha256" >&2; exit 1; }
}
fetch() { # <url> <file> <sha256>
	mkdir -p "$(dirname "$2")"
	if [ ! -s "$2" ]; then
		curl -sSfL -o "$2.part" "$1"
		mv "$2.part" "$2"
	fi
	check "$2" "$3"
}
fetch_aosp() { # <name> <sha256>; gitiles serves files base64-encoded
	mkdir -p "$T/aosp-testkeys"
	local f="$T/aosp-testkeys/$1"
	if [ ! -s "$f" ]; then
		curl -sSfL "$AOSP/$1?format=TEXT" | base64 -d >"$f.part"
		mv "$f.part" "$f"
	fi
	check "$f" "$2"
}

[ -z "$GSI_TOO" ] || fetch https://github.com/TrebleDroid/treble_experimentations/releases/download/ci-20230905/system-td-arm64-ab-vanilla.img.xz \
	"$ROOT/gsi/system-td-arm64-ab-vanilla-ci-20230905.img.xz" \
	e3bfcc02fd5cfdf358c6d4792d746f8cce49899382ba7ece1df7e3fe72de154e
fetch_aosp platform.pk8 1ad8ef556870edb70f69a9d3c112544c07de5162ba440d84d33f8bb0c5962875
fetch_aosp platform.x509.pem 9837de028f460c35cc8d3fa45f14eecce30f6fbfe4b93d399aef1acb80c20d14
if [ ! -s "$T/build-tools-dl/build-tools_r34-linux.zip" ] && [ "${ANDROID_SDK_LICENSE:-}" != accepted ]; then
	echo "Google's build-tools 34 come under the Android SDK License Agreement" \
		"(https://developer.android.com/studio/terms). Once you agree, run again with" \
		"ANDROID_SDK_LICENSE=accepted." >&2
	exit 3
fi
fetch https://dl.google.com/android/repository/build-tools_r34-linux.zip \
	"$T/build-tools-dl/build-tools_r34-linux.zip" \
	e858c4b60069d0431051b225d384413b1643e1289b00a4825aed347f25bd510f
fetch $MAVEN/org/smali/dexlib2/2.5.2/dexlib2-2.5.2.jar "$T/dexlib2-dl/dexlib2-2.5.2.jar" \
	5a5c8982d8bd7d6e3bb1a0713049e3c78b719ec32b20f6b619885cec30a0dd61
fetch $MAVEN/com/google/guava/guava/27.1-android/guava-27.1-android.jar "$T/dexlib2-dl/guava-27.1-android.jar" \
	686404f2d1d4d221911f96bd627ff60dac2226a5dfa6fb8ba517073eb97ec0ef
fetch https://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-6+b9_arm64.deb \
	"$T/busybox-dl/busybox-static_1.37.0-6+b9_arm64.deb" \
	c833be48abfa16bc19c4966ec93e289ff1ce5d2f1476cad3a57bd105378cd15c
fetch https://deb.debian.org/debian/pool/main/q/qemu/qemu-user_10.0.13+ds-0+deb13u1_amd64.deb \
	"$T/qemu-dl/qemu-user_10.0.13+ds-0+deb13u1_amd64.deb" \
	ca6ede739327a20ae5a3498230c8a3a9a072c586e131bc6bcc1201eb1725e336

if [ -z "${KIT_FROM_SOURCE:-}" ]; then
	while read -r sha name; do
		fetch "$PREBUILT/$name" "$T/prebuilt/$name" "$sha"
	done <"$ROOT/kit/prebuilt.sha256"
fi

GSI="$ROOT/gsi/system-td-arm64-ab-vanilla-ci-20230905.img"
[ -z "$GSI_TOO" ] || [ -s "$GSI" ] || { xz -dc "$GSI.xz" >"$GSI.part" && mv "$GSI.part" "$GSI"; }
[ -x "$T/build-tools-dl/x/android-14/apksigner" ] ||
	unzip -q -o "$T/build-tools-dl/build-tools_r34-linux.zip" -d "$T/build-tools-dl/x"
if [ ! -x "$T/busybox-dl/x/usr/bin/busybox" ]; then
	mkdir -p "$T/busybox-dl/x"
	(cd "$T/busybox-dl/x" && ar x ../busybox-static_1.37.0-6+b9_arm64.deb && tar -xf data.tar.* ./usr/bin/busybox)
fi
if [ ! -x "$T/qemu-dl/x/usr/bin/qemu-aarch64" ]; then
	mkdir -p "$T/qemu-dl/x"
	(cd "$T/qemu-dl/x" && ar x ../qemu-user_10.0.13+ds-0+deb13u1_amd64.deb && tar -xf data.tar.* ./usr/bin/qemu-aarch64)
fi
echo "tools ready"
