QT += quick qml
CONFIG += c++11
TEMPLATE = app
TARGET = a55ui

SOURCES += src/main.cpp src/stubmodel.cpp
HEADERS += src/stubmodel.h src/coverart.h src/testscript.h

# Written by scripts/stage.py (build.sh runs it first): this repo's QML and screen
# specs plus the generated stubs. The Sony resources are not compiled in; they
# are read at run time from stock.rcc (APK assets on Android).
RESOURCES += $$PWD/build/gen/app.qrc

android {
    ANDROID_PACKAGE_SOURCE_DIR = $$PWD/build/android-pkg
    ANDROID_MIN_SDK_VERSION = 21
    ANDROID_TARGET_SDK_VERSION = 28
    ANDROID_VERSION_NAME = 0.1
    ANDROID_VERSION_CODE = 1
    # androiddeployqt reads the QML imports of the files under this directory to
    # decide which Qt QML modules to bundle. The Sony QML sits in a binary
    # resource it cannot see, so the imports are listed in qml-imports/.
    QML_ROOT_PATH = $$PWD/qml-imports
}
