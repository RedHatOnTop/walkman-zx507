#!/usr/bin/env python3
"""Write install.json for an install set make-install.sh built: what goes to which partition,
the hashes of what is sent, and what a booted unit must show for the install to count.

With --stock, for the set make-restore.sh links together instead: the four stock partitions
as Sony's firmware has them, so slot b runs stock again. The hashes are the kit's pins, which
unpack-stock.sh has just checked the images against.

The read-back after boot needs no root: the kernel's banner is /proc/version, and the files in
`check` are world-readable on the running system, so `sha256sum` as the shell user sees them.

Usage: install-json.py <out-dir> <kernel-Image> <stock-pins.sha256> > install.json
       install-json.py --stock <out-dir> <stock-pins.sha256> > install.json
Reads RELEASE and KEEP_SU from the environment, as build-image.sh does.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

KIT = "nw-zx500-android13"
CHECK = [
    "/system/framework/services.jar",
    "/system/framework/framework-res.apk",
    "/system/system_ext/priv-app/SystemUI/SystemUI.apk",
    "/system/system_ext/etc/build.prop",
]
# Stock's /system/build.prop is 0600; these three are world-readable there.
STOCK_CHECK = [
    "/system/framework/services.jar",
    "/system/framework/framework-res.apk",
    "/system/priv-app/SystemUI/SystemUI.apk",
]
# A file only this kit's system has (compat-gsi.sh), which stock must not.
MARKER = "/system/etc/init/zx507-audio.rc"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def commit(root):
    stamp = open(os.path.join(root, "kit", "COMMIT")).read().strip()
    if re.fullmatch(r"[0-9a-f]{40}", stamp):
        return stamp, False
    head = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True)
    dirty = subprocess.run(
        ["git", "-C", root, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True
    )
    if head.returncode != 0:
        return None, False
    return head.stdout.strip(), bool(dirty.stdout.strip())


def banner(kernel):
    data = open(kernel, "rb").read()
    m = re.search(rb"Linux version [^\n\0]+", data)
    if not m:
        sys.exit(f"{kernel}: no Linux version banner")
    return m.group(0).decode("ascii", "replace").rstrip()


def firmware_of(pins):
    m = re.match(r"# (\S+) (\S+), series (\d{4})\.", open(pins).readline())
    return m.groups() if m else (None, None, None)


def stock_check(system):
    """The STOCK_CHECK files' hashes as the stock system image holds them, read with debugfs."""
    check = []
    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(system))) as tmp:
        for i, path in enumerate(STOCK_CHECK):
            st = subprocess.run(["debugfs", "-R", f"stat {path}", system], capture_output=True, text=True)
            m = re.search(r"Type: (\S+)\s+Mode:\s+([0-7]+)", st.stdout)
            if not m or m.group(1) != "regular" or not int(m.group(2), 8) & 0o004:
                sys.exit(f"{path} is not a world-readable file in {system}")
            dump = os.path.join(tmp, str(i))
            subprocess.run(["debugfs", "-R", f"dump {path} {dump}", system], capture_output=True, check=True)
            check.append({"path": path, "sha256": sha256(dump)})
    return check


def stock(out, pins):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rev, dirty = commit(root)
    model, firmware, series = firmware_of(pins)
    pinned = {}
    for line in open(pins):
        if not line.startswith("#") and line.strip():
            digest, name = line.split()
            pinned[name] = digest
    files = {}
    for name in ("vbmeta.img", "boot.img", "system.img", "vendor.img"):
        files[name] = {"bytes": os.path.getsize(os.path.join(out, name)), "sha256": pinned[name]}
    return {
        "kit": KIT,
        "commit": rev,
        "dirty": dirty,
        "variant": "stock",
        "root": False,
        "model": model,
        "firmware": firmware,
        "series": series,
        "slot": "b",
        "files": files,
        "flash": [
            {"partition": "vbmeta_b", "file": "vbmeta.img"},
            {"partition": "boot_b", "file": "boot.img"},
            {"partition": "system_b", "file": "system.img"},
            {"partition": "vendor_b", "file": "vendor.img"},
        ],
        "after": {
            "kernel": banner(os.path.join(out, "boot.img")),
            "check": stock_check(os.path.join(out, "system.img")),
            "absent": [MARKER],
        },
    }


def main():
    if sys.argv[1] == "--stock":
        json.dump(stock(*sys.argv[2:4]), sys.stdout, indent=2)
        sys.stdout.write("\n")
        return
    out, kernel, pins = sys.argv[1:4]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    release = bool(os.environ.get("RELEASE"))
    root_shell = not release or bool(os.environ.get("KEEP_SU"))
    rev, dirty = commit(root)
    model, firmware, series = firmware_of(pins)

    manifest = {}
    for line in open(os.path.join(out, "manifest.tsv")):
        path, kind, mode, _owner, _size, digest = line.split("\t")[:6]
        manifest[path] = (kind, int(mode, 8), digest)
    check = []
    for path in CHECK:
        kind, mode, digest = manifest[path]
        if kind != "regular" or not mode & 0o004:
            sys.exit(f"{path} is not a world-readable file in system.img")
        check.append({"path": path, "sha256": digest})

    files = {}
    for name in ("system.img", "boot.img", "vbmeta.img"):
        p = os.path.join(out, name)
        files[name] = {"bytes": os.path.getsize(p), "sha256": sha256(p)}
    doc = {
        "kit": KIT,
        "commit": rev,
        "dirty": dirty,
        "variant": "release" if release else "debug",
        "root": root_shell,
        "model": model,
        "firmware": firmware,
        "series": series,
        "slot": "b",
        "files": files,
        "flash": [
            {"partition": "vbmeta_b", "file": "vbmeta.img"},
            {"partition": "boot_b", "file": "boot.img"},
            {"partition": "system_b", "file": "system.img"},
        ],
        "after": {
            "kernel": banner(kernel),
            "check": check,
            "absent": [] if root_shell else ["/system/xbin/su"],
        },
    }
    json.dump(doc, sys.stdout, indent=2)
    sys.stdout.write("\n")


main()
