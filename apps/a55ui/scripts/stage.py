"""Stage everything a55ui builds from, into one gitignored build directory.

    stage.py --src NW_A55_REPO --rcc PATH/TO/rcc [--out BUILD_DIR]

The Sony resources (QML, images, fonts, translations) are proprietary. They are
read from the nw-a55 repo's gitignored work/ area and written only below
BUILD_DIR (apps/a55ui/build, gitignored). Nothing here is copied anywhere else.

Produces, under BUILD_DIR:
  res/stock.rcc       Sony QML + images + the /opt2 images, as one binary resource
  res/fonts/, fonts.txt, tr/*.qm
  gen/app.qrc         this repo's QML and screen specs, and the generated stubs
  gen/stubs/*.qml     the four global context objects (scripts/gen_stubs.py)
  android-pkg/        ANDROID_PACKAGE_SOURCE_DIR: manifest + assets/res/
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)

# Fonts the English and Korean UI needs. The CJK and Thai families the A55 also
# ships are left out for now; Android falls back to its own.
FONT_PREFIXES = ("SST-", "SSTUI-", "NotoSansKR-")
LANGS = ("en_US", "ko_KR")


def write_qrc(path, root, entries):
    """entries: (alias, file path). Paths are written relative to the qrc."""
    base = os.path.dirname(path)
    with open(path, "w") as f:
        f.write('<RCC>\n  <qresource prefix="/">\n')
        for alias, full in entries:
            rel = os.path.relpath(full, base)
            f.write("    <file alias=%s>%s</file>\n" % (quoteattr(alias), rel.replace("&", "&amp;")))
        f.write("  </qresource>\n</RCC>\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="nw-a55 repo")
    ap.add_argument("--rcc", required=True, help="Qt rcc binary")
    ap.add_argument("--out", default=os.path.join(APP, "build"))
    args = ap.parse_args()

    work = os.path.join(args.src, "work")
    qrc_device = os.path.join(work, "qrc-device")
    opt2 = os.path.join(work, "device", "opt2", "appresouce")
    sysdir = os.path.join(work, "device", "system", "vendor", "sony")
    moc = os.path.join(work, "moc-app-device.json")
    for p in (qrc_device, opt2, sysdir, moc):
        if not os.path.exists(p):
            sys.exit("missing %s (see tools/uisim.sh and docs/phase1-ui.md in the nw-a55 repo)" % p)

    out = os.path.abspath(args.out)
    # Only ever delete our own generated directories.
    for sub in ("stage", "res", "gen", "android-pkg"):
        shutil.rmtree(os.path.join(out, sub), ignore_errors=True)
    stage = os.path.join(out, "stage", "qrc")
    res = os.path.join(out, "res")
    gen = os.path.join(out, "gen")
    os.makedirs(res)
    os.makedirs(os.path.join(gen, "stubs"))

    # --- the Sony QML tree, with the two edits a Qt 5.15 build needs --------
    shutil.copytree(qrc_device, stage)

    # Qt 5.3 (the A55's) has QQuickItemView::modelReset; 5.15 does not, and a
    # handler for a missing signal is an error at load time.
    edv = os.path.join(stage, "components", "EdgeDetectListView.qml")
    text = open(edv, encoding="utf-8").read()
    text, n = re.subn(r"^([ \t]*)onModelReset:.*$", r"\1// a55ui: Qt 5.3-only handler removed",
                      text, flags=re.M)
    if n != 1:
        sys.exit("EdgeDetectListView.qml: expected one onModelReset handler, found %d" % n)
    open(edv, "w", encoding="utf-8").write(text)

    # Qt 5.3 (the A55's) lets a Repeater instantiate non-visual delegates. Qt 5.15
    # does not: "Delegate must be of Item type", and 5.15.2 (the Android kit)
    # then crashes in QQmlIncubatorPrivate::incubate as soon as the Repeater has a
    # model (Debian's 5.15.8 only warns). The two header files that do this feed
    # the volume bar from a model; Instantiator is the Qt 5.15 type for exactly
    # that, and it keeps the model-driven volume working.
    for name in ("StatusVolumeBar.qml", "VolumeArea.qml"):
        path = os.path.join(stage, "components", name)
        text = open(path, encoding="utf-8").read()
        text, n = re.subn(r"\bRepeater(\s*\{\s*model\s*:\s*volumeOperateInfo\b)", r"Instantiator\1", text)
        if n != 1:
            sys.exit("%s: expected one Repeater over volumeOperateInfo, found %d" % (name, n))
        # Instantiator lives in QtQml 2.x; the file only imports QtQuick 2.x.
        text = re.sub(r"^(import QtQuick [0-9.]+\n)", r"\1import QtQml 2.2\n", text, count=1, flags=re.M)
        open(path, "w", encoding="utf-8").write(text)

    # Guard: no other Repeater may have a non-visual delegate (see above).
    bad = []
    for dirpath, _, files in os.walk(stage):
        for name in files:
            if name.endswith(".qml"):
                text = open(os.path.join(dirpath, name), encoding="utf-8").read()
                if re.search(r"\bRepeater\s*\{\s*(?:\w[\w.]*\s*:[^\n{}]*\n\s*)*(?:QtObject|Binding|Connections|Timer)\s*\{", text):
                    bad.append(os.path.relpath(os.path.join(dirpath, name), stage))
    if bad:
        sys.exit("Repeater with a non-Item delegate (crashes Qt 5.15.2): %s" % ", ".join(bad))

    # The A55 reads some images from its option2 partition as file:/opt2/...;
    # there is no such path on Android, so they ride in the resource instead.
    shutil.copytree(opt2, os.path.join(stage, "opt2", "appresouce"))
    n = 0
    for dirpath, _, files in os.walk(stage):
        for name in files:
            if name.endswith((".qml", ".js")):
                p = os.path.join(dirpath, name)
                s = open(p, encoding="utf-8").read()
                t = s.replace("file:/opt2/appresouce/", "qrc:/opt2/appresouce/")
                if t != s:
                    open(p, "w", encoding="utf-8").write(t)
                    n += 1
    print("opt2 paths rewritten in %d QML files" % n)

    entries = []
    for dirpath, _, files in os.walk(stage):
        for name in files:
            full = os.path.join(dirpath, name)
            entries.append((os.path.relpath(full, stage).replace(os.sep, "/"), full))
    entries.sort()
    stock_qrc = os.path.join(out, "stage", "stock.qrc")
    write_qrc(stock_qrc, stage, entries)
    subprocess.run([args.rcc, "--binary", "-o", os.path.join(res, "stock.rcc"), stock_qrc], check=True)
    print("stock.rcc: %d files, %d bytes" % (len(entries), os.path.getsize(os.path.join(res, "stock.rcc"))))

    # --- fonts and translations -----------------------------------------
    os.makedirs(os.path.join(res, "fonts"))
    fonts = []
    for name in sorted(os.listdir(os.path.join(sysdir, "lib", "fonts"))):
        if name.startswith(FONT_PREFIXES):
            shutil.copy(os.path.join(sysdir, "lib", "fonts", name), os.path.join(res, "fonts", name))
            fonts.append(name)
    open(os.path.join(res, "fonts.txt"), "w").write("\n".join(fonts) + "\n")
    os.makedirs(os.path.join(res, "tr"))
    for lang in LANGS:
        shutil.copy(os.path.join(sysdir, "translations", "HgrmMediaPlayerApp_%s.qm" % lang),
                    os.path.join(res, "tr"))
    print("fonts: %s" % ", ".join(fonts))

    # --- stubs for the global context objects ---------------------------
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "gen_stubs.py"), moc,
                    os.path.join(sysdir, "bin", "ScreenSettings.json"),
                    os.path.join(APP, "config", "globals.json"), os.path.join(gen, "stubs")],
                   check=True, stdout=subprocess.DEVNULL)

    # --- this repo's own resources -------------------------------------
    own = []
    for sub, ext in (("qml", ".qml"), ("screens", ".json")):
        for name in sorted(os.listdir(os.path.join(APP, sub))):
            if name.endswith(ext):
                own.append(("%s/%s" % (sub, name), os.path.join(APP, sub, name)))
    for name in sorted(os.listdir(os.path.join(gen, "stubs"))):
        own.append(("stubs/" + name, os.path.join(gen, "stubs", name)))
    write_qrc(os.path.join(gen, "app.qrc"), APP, own)

    # --- Android package source dir ------------------------------------
    pkg = os.path.join(out, "android-pkg")
    os.makedirs(os.path.join(pkg, "assets"))
    shutil.copy(os.path.join(APP, "android", "AndroidManifest.xml"), pkg)
    shutil.copytree(res, os.path.join(pkg, "assets", "res"))
    print("staged into %s" % out)


if __name__ == "__main__":
    main()
