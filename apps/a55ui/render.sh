#!/bin/bash
#
# Render the app's screens to PNG on the host, with the same QML, stubs and
# Sony resources the APK carries. The container (Xvfb + Mesa, like the nw-a55
# repo's tools/uisim.sh) only supplies the system libraries; Qt itself is the
# 5.15.2 desktop kit from lib/toolchain.sh, the same release as the APK's. (The
# container's own Qt is 5.15.8, which hid a Qt 5.15.2 crash in Repeater.)
# No device, no GPU, no desktop window.
#
#   ./render.sh [--size WxH] [--lang en_US] [SCREEN_ID ...]
#   ./render.sh --script 'wait:1500;tap:360,1250;wait:800;grab:/out/x.png' [SCREEN_ID]
#
# Default: every screen in screens/*.json at 720x1280. PNGs and logs land in
# build/render/ (gitignored: they show Sony's UI). --script drives one run from
# the given screen with taps and grabs (steps in src/testscript.h; /out is
# build/render).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${A55_SRC:-$HOME/Projects/nw-a55}"
SIZE=720x1280
LANG_ID=en_US
SCRIPT=
while [ $# -gt 0 ]; do
    case "$1" in
        --size) SIZE="$2"; shift 2 ;;
        --lang) LANG_ID="$2"; shift 2 ;;
        --script) SCRIPT="$2"; shift 2 ;;
        *) break ;;
    esac
done
SCREENS=("$@")
if [ ${#SCREENS[@]} -eq 0 ]; then
    for f in "$HERE"/screens/*.json; do SCREENS+=("$(basename "$f" .json)"); done
fi

. "$HERE/lib/toolchain.sh"
find_rcc
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I "$HERE/scripts/stage.py" \
    --src "$SRC" --rcc "$RCC" --out "$HERE/build"

IMAGE="${A55UI_RENDER_IMAGE:-}"
if [ -z "$IMAGE" ]; then
    if docker image inspect nw-probe-hosttest:3 > /dev/null 2>&1; then
        IMAGE=nw-probe-hosttest:3
    else
        IMAGE=a55ui-render:1
        docker image inspect "$IMAGE" > /dev/null 2>&1 ||
            docker build -t "$IMAGE" -f "$HERE/docker/Dockerfile.render" "$HERE/docker"
    fi
fi

OUT="$HERE/build/render"
mkdir -p "$OUT" "$HERE/build/host"
# A build directory configured by the other Qt must not be reused.
if [ -f "$HERE/build/host/Makefile" ] && ! grep -q "/qt/include" "$HERE/build/host/Makefile"; then
    rm -f "$HERE/build/host/Makefile" "$HERE/build/host/"*.o
fi
docker run --rm --init -u "$(id -u):$(id -g)" \
    -v "$QT_DIR/gcc_64":/qt:ro -v "$HERE":/src:ro -v "$HERE/build/host":/build -v "$HERE/build/res":/res:ro -v "$OUT":/out \
    -e HOME=/tmp -e DISPLAY=:99 -w /build "$IMAGE" /bin/bash -c "
        set -e
        /qt/bin/qmake /src/a55ui.pro CONFIG+=release > /dev/null
        make -j2 > make.log 2>&1 || { cat make.log; exit 1; }
        Xvfb :99 -screen 0 1600x1600x24 -nolisten tcp 2> /dev/null &
        for i in \$(seq 50); do test -e /tmp/.X11-unix/X99 && break; sleep 0.1; done
        status=0
        if [ -n '$SCRIPT' ]; then
            A55UI_RES=/res A55UI_SIZE=$SIZE A55UI_LANG=$LANG_ID A55UI_SCREEN=${SCREENS[0]} \
                A55UI_SCRIPT='$SCRIPT' ./a55ui 2> /out/script.log || status=1
            echo \"script: \$(grep -c . /out/script.log) log lines, exit \$status\"
        else
        for s in ${SCREENS[*]}; do
            A55UI_RES=/res A55UI_SIZE=$SIZE A55UI_LANG=$LANG_ID A55UI_SCREEN=\$s \
                A55UI_GRAB=/out/\$s.png ./a55ui 2> /out/\$s.log || status=1
            echo \"\$s: \$(grep -c . /out/\$s.log) log lines, exit \$status\"
        done
        fi
        exit \$status"
echo "PNGs in $OUT"
