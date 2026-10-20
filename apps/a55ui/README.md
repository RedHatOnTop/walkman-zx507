# a55ui

The Sony NW-A55 Walkman's own UI as an Android app (Qt 5.15 for Android, arm64-v8a),
for the NW-ZX507. First milestone: render A55 screens, no playback.

The A55 UI is QML (Qt 5.3 there) bound by name to C++ ViewModels. This app loads that
QML unchanged and feeds it constants instead of ViewModels:

- `scripts/stage.py` pulls the Sony QML, images, fonts and translations out of the
  nw-a55 repo's gitignored `work/` into `build/` (gitignored) and packs the QML as
  `stock.rcc`. Two edits are made to the staged copy only: the Qt 5.3-only
  `onModelReset` handler is dropped, `file:/opt2/appresouce/` image paths (the
  A55's option2 partition) point into the resource instead, and the two header
  `Repeater`s over `volumeOperateInfo` become `Instantiator` (see below).
- `scripts/gen_stubs.py` generates QML stand-ins for the four global context objects
  (`screenController`, `appFont`, `dialogManager`, `holdToastManager`) from the app's
  moc data.
- `screens/*.json` say, per screen, which QML to load, which window chrome (header,
  transport, navigation bar) goes with it, and the values a ViewModel would push.
  `{"$model": {...}}` entries become list models (`src/stubmodel.*`).
- `qml/Host.qml` plays FrameWork.qml: it holds the current screen, scales the 480-px
  A55 layout to the display width (1.5x on 720x1280, so the stage is 480x853), and
  switches screens.
- `src/main.cpp` registers the resources and runs it. On Android they come from the
  APK assets (`assets:/res`), on a desktop from `$A55UI_RES`.

Sony assets are never committed: `build/`, `toolchain/`, `*.apk` and `*.rcc` are
gitignored, and the APK contains Sony's QML, images and fonts, so it stays local.

## Build

```
./build.sh                   # -> build/a55ui-arm64-v8a-debug.apk (debug-signed, installable)
./render.sh                  # every screen -> build/render/*.png (Docker libs + the APK's Qt 5.15.2)
./render.sh --script 'wait:1500;tap:270,1250;wait:800;grab:/out/x.png' home
                             # steps: wait, tap, hold, drag, key:back, grab (src/testscript.h)
./setup-toolchain.sh         # optional: Qt, SDK/NDK r21e, JDK 11 into toolchain/
```

Prerequisite: the nw-a55 repo's `work/` must have the extracted resources
(`tools/uisim.sh` there creates `work/qrc-device`, `work/moc-app-device.json`,
`work/device/system`, `work/device/opt2`). `A55_SRC` points elsewhere.
`lib/toolchain.sh` finds Qt/SDK/JDK in `toolchain/`, else in the nw-a55 repo's
`work/` and `~/Android/sdk`. Builds use `make -j2`.

## Qt version matters

The APK is Qt 5.15.2; Debian's Qt (the container's own) is 5.15.8. Qt 5.15.2 segfaults in
`QQmlIncubatorPrivate::incubate` when a `Repeater` with a non-Item delegate (`QtObject`)
gets a model; 5.15.8 only warns ("Delegate must be of Item type"). The A55's volume bar
does exactly that, which crashed the first APK on the ZX507. `render.sh` therefore builds
against the toolchain's 5.15.2 desktop kit, and `scripts/stage.py` rewrites those two
Repeaters and refuses to stage if any other Repeater has a non-Item delegate. The
Android-style extraction is off in the manifest (`extract_android_style=none`); main.cpp
forces the Quick Controls 1 Base style.

## Using it

Screens: Home (library top), Now playing, Settings. The navigation bar works:
Library goes home, Now playing goes to the player, the toolbox (Option) opens
Settings, Back steps back. Back at the start, or the tab on the right edge, opens a
list of screens. Play/pause toggles and the position counts up; nothing is played.

## Not done

Real playback and ViewModels; the option menu dialog (DialogManager is a stub);
screens other than the three above (all 94 `sid_*` screens load, but need values);
CJK and Thai fonts (Android falls back to its own); the status bar icon row beside
the volume bar on Home/Settings.
