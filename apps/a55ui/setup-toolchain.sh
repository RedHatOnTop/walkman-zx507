#!/bin/bash
#
# Install what build.sh needs into apps/a55ui/toolchain/ (gitignored), from
# binaries only (nothing is compiled from source):
#
#   Qt 5.15.2          desktop gcc_64 (host tools: rcc, moc) + android kit (arm64-v8a, ...)
#                      via aqtinstall, into toolchain/Qt
#   Android SDK        build-tools 28.0.3, platform android-28, NDK r21e (21.4.7075529),
#                      into toolchain/android-sdk
#   JDK 11             Eclipse Temurin, into toolchain/jdk11 (Qt 5.15's gradle project
#                      needs JDK <= 12)
#
# build.sh and render.sh also work without this: lib/toolchain.sh falls back to the
# copies the nw-a55 repo keeps under work/ (Qt, jdk11) and ~/Android/sdk.
#
# Android SDK licences: set A55UI_ACCEPT_ANDROID_SDK_LICENSE=1 to accept
# https://developer.android.com/studio/terms for this install; otherwise the licence
# hashes already accepted in ~/Android/sdk/licenses are reused when present.
#
# Needs: python3 (+venv), curl, unzip, tar, and a JDK >= 17 for sdkmanager (the host's).
# Download: about 1.2 GB (Qt), 1 GB (NDK), 0.2 GB (JDK), small rest. Disk: ~5 GB.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TC="${A55UI_TOOLCHAIN:-$HERE/toolchain}"
QT_VERSION=5.15.2
NDK_VERSION=21.4.7075529
CMDLINE_TOOLS_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip}"
JDK11_URL="${JDK11_URL:-https://api.adoptium.net/v3/binary/latest/11/ga/linux/x64/jdk/hotspot/normal/eclipse}"

mkdir -p "$TC"

# --- Qt ---------------------------------------------------------------------
if [ ! -x "$TC/Qt/$QT_VERSION/android/bin/qmake" ] || [ ! -x "$TC/Qt/$QT_VERSION/gcc_64/bin/rcc" ]; then
    if [ ! -x "$TC/aqt-venv/bin/aqt" ]; then
        env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -m venv "$TC/aqt-venv"
        "$TC/aqt-venv/bin/pip" install --quiet aqtinstall
    fi
    "$TC/aqt-venv/bin/aqt" install-qt linux desktop "$QT_VERSION" gcc_64 --outputdir "$TC/Qt"
    "$TC/aqt-venv/bin/aqt" install-qt linux android "$QT_VERSION" android --outputdir "$TC/Qt"
fi

# --- JDK 11 -------------------------------------------------------------------
if [ ! -x "$TC/jdk11/bin/java" ]; then
    mkdir -p "$TC/jdk11-dl"
    curl -fL --retry 3 -o "$TC/jdk11-dl/jdk11.tar.gz" "$JDK11_URL"
    mkdir -p "$TC/jdk11"
    tar -xzf "$TC/jdk11-dl/jdk11.tar.gz" -C "$TC/jdk11" --strip-components=1
fi

# --- Android SDK + NDK -----------------------------------------------------------
SDK="$TC/android-sdk"
if [ ! -d "$SDK/ndk/$NDK_VERSION" ] || [ ! -d "$SDK/build-tools/28.0.3" ] || [ ! -d "$SDK/platforms/android-28" ]; then
    command -v java > /dev/null || { echo "sdkmanager needs a JDK >= 17 on PATH" >&2; exit 1; }
    mkdir -p "$SDK/cmdline-tools" "$TC/sdk-dl"
    if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
        curl -fL --retry 3 -o "$TC/sdk-dl/cmdline-tools.zip" "$CMDLINE_TOOLS_URL"
        unzip -q -o "$TC/sdk-dl/cmdline-tools.zip" -d "$TC/sdk-dl/ct"
        mkdir -p "$SDK/cmdline-tools/latest"
        cp -r "$TC/sdk-dl/ct/cmdline-tools/." "$SDK/cmdline-tools/latest/"
    fi
    mkdir -p "$SDK/licenses"
    if [ "${A55UI_ACCEPT_ANDROID_SDK_LICENSE:-0}" = 1 ]; then
        yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses > /dev/null || true
    elif [ -d "$HOME/Android/sdk/licenses" ]; then
        cp "$HOME/Android/sdk/licenses/"* "$SDK/licenses/"
    else
        echo "Set A55UI_ACCEPT_ANDROID_SDK_LICENSE=1 to accept the Android SDK licence." >&2
        exit 1
    fi
    "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" \
        "platforms;android-28" "build-tools;28.0.3" "ndk;$NDK_VERSION"
fi

echo "toolchain ready in $TC"
