#!/usr/bin/env python3
"""Write install.json for an install set make-install.sh built: what goes to which partition,
the hashes of what is sent, and what a booted unit must show for the install to count.

The read-back after boot needs no root: the kernel's banner is /proc/version, and the files in
`check` are world-readable on the running system, so `sha256sum` as the shell user sees them.

Usage: install-json.py <out-dir> <kernel-Image> <stock-pins.sha256> > install.json
Reads RELEASE and KEEP_SU from the environment, as build-image.sh does.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

KIT = "nw-zx500-android13"
CHECK = [
    "/system/framework/services.jar",
    "/system/framework/framework-res.apk",
    "/system/system_ext/priv-app/SystemUI/SystemUI.apk",
    "/system/system_ext/etc/build.prop",
]


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


def main():
    out, kernel, pins = sys.argv[1:4]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    release = bool(os.environ.get("RELEASE"))
    root_shell = not release or bool(os.environ.get("KEEP_SU"))
    rev, dirty = commit(root)
    first = open(pins).readline()
    m = re.match(r"# (\S+) (\S+), series (\d{4})\.", first)
    model, firmware, series = m.groups() if m else (None, None, None)

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
