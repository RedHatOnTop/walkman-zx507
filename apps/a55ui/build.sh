#!/bin/bash
#
# Build the A55 UI app as an Android APK (arm64-v8a, Qt 5.15.2).
#
#   ./build.sh [apk]            stage + build the APK  -> build/a55ui-arm64-v8a-debug.apk
#   ./build.sh stage            only stage the resources (build/)
#   ABI=armeabi-v7a ./build.sh  another ABI (default arm64-v8a: the ZX507 is arm64)
#
# The Sony resources (QML, images, fonts, translations) are staged from
# $A55_SRC/work (default ~/Projects/nw-a55; run tools/uisim.sh there once) into
# build/, which is gitignored. The APK contains them: keep it local, never
# commit or publish it.
#
# Toolchain: see lib/toolchain.sh and setup-toolchain.sh. Qt 5.15.2 generates a
# gradle 5.6.4 / AGP 3.6.0 / build-tools 28.0.3 project, which needs JDK <= 12,
# so the gradle step runs with JDK 11 (not the system JDK).
#
# Load: make -j2 (this machine has 16 GB and must stay usable). No Qt build from
# source; Qt comes as aqt binaries. Gradle may download its own distribution on a
# first run; it is cached under ~/.gradle afterwards.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${A55_SRC:-$HOME/Projects/nw-a55}"
ABI="${ABI:-arm64-v8a}"
JOBS=2
CMD="${1:-apk}"

. "$HERE/lib/toolchain.sh"
find_android

env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$HERE/scripts/stage.py" \
    --src "$SRC" --rcc "$RCC" --out "$HERE/build"
[ "$CMD" = stage ] && exit 0
[ "$CMD" = apk ] || { echo "usage: $0 [apk|stage]" >&2; exit 2; }

# A clean tree every time: a build directory configured by another Qt or NDK
# would otherwise be reused half-stale, and the whole build takes about two minutes.
B="$HERE/build/android-$ABI"
case "$B" in "$HERE"/build/android-*) rm -rf -- "$B" ;; *) exit 1 ;; esac
mkdir -p "$B"
cd "$B"
echo "Qt $QT_DIR, SDK $ANDROID_SDK_ROOT, JDK $JAVA_HOME"

"$QT_DIR/android/bin/qmake" "$HERE/a55ui.pro" -spec android-clang CONFIG+=release "ANDROID_ABIS=$ABI"
make -j"$JOBS"
make INSTALL_ROOT="$B/apk-root" install
"$QT_DIR/android/bin/androiddeployqt" \
    --input "$B/android-a55ui-deployment-settings.json" \
    --output "$B/apk-root" --android-platform android-28 --gradle

APK="$(find "$B/apk-root/build/outputs/apk" -name '*.apk' | head -1)"
[ -n "$APK" ] || { echo "no APK produced" >&2; exit 1; }
cp "$APK" "$HERE/build/a55ui-$ABI-debug.apk"
echo "APK: $HERE/build/a55ui-$ABI-debug.apk ($(du -h "$HERE/build/a55ui-$ABI-debug.apk" | cut -f1))"
"$ANDROID_SDK_ROOT/build-tools/28.0.3/aapt" dump badging "$HERE/build/a55ui-$ABI-debug.apk" |
    grep -E "^(package|sdkVersion|targetSdkVersion|launchable-activity|native-code|application-label:)" || true
