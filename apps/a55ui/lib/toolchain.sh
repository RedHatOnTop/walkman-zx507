# Locates the Qt / Android SDK / NDK / JDK that build.sh and render.sh use.
# Sourced, not run; the caller sets HERE (apps/a55ui). Order: apps/a55ui/toolchain/
# (setup-toolchain.sh installs there), else the copies the nw-a55 repo keeps
# under its gitignored work/.
#
# Override any of them with QT_DIR, ANDROID_SDK_ROOT, JAVA_HOME_A55.

A55_SRC="${A55_SRC:-$HOME/Projects/nw-a55}"
TC="${A55UI_TOOLCHAIN:-$HERE/toolchain}"
NDK_VERSION=21.4.7075529   # the NDK Qt 5.15 supports (r21e)
QT_VERSION=5.15.2

first_dir() {
    for d in "$@"; do
        if [ -n "$d" ] && [ -d "$d" ]; then echo "$d"; return 0; fi
    done
    return 1
}

# Host rcc only (render.sh): the Android kit is not needed for that.
find_rcc() {
    QT_DIR="${QT_DIR:-$(first_dir "$TC/Qt/$QT_VERSION" "$A55_SRC/work/Qt/$QT_VERSION" || true)}"
    RCC="${RCC:-${QT_DIR:-/nonexistent}/gcc_64/bin/rcc}"
    [ -x "$RCC" ] || { echo "no host rcc at $RCC; run ./setup-toolchain.sh" >&2; exit 1; }
}

find_android() {
    find_rcc
    [ -x "$QT_DIR/android/bin/qmake" ] ||
        { echo "no Qt $QT_VERSION for Android under $QT_DIR; run ./setup-toolchain.sh" >&2; exit 1; }
    ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$(first_dir "$TC/android-sdk" "$HOME/Android/sdk" || true)}"
    JAVA_HOME="${JAVA_HOME_A55:-$(first_dir "$TC/jdk11" "$A55_SRC/work/jdk11" || true)}"
    ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
    for p in "$ANDROID_NDK_ROOT" "$ANDROID_SDK_ROOT/build-tools/28.0.3" \
             "$ANDROID_SDK_ROOT/platforms/android-28" "$JAVA_HOME"; do
        [ -d "$p" ] || { echo "missing $p; run ./setup-toolchain.sh" >&2; exit 1; }
    done
    export ANDROID_SDK_ROOT ANDROID_NDK_ROOT JAVA_HOME
    export PATH="$JAVA_HOME/bin:$PATH"
}
