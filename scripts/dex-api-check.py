#!/usr/bin/env python3
"""Check an app's framework API references against a target boot classpath.

Every method, field and class an APK references outside its own dex is
resolved Java-style against a set of boot jars: the class chain first, then
superinterfaces. Anything that does not resolve would throw NoSuchMethodError,
NoSuchFieldError or NoClassDefFoundError on that system. With `--baseline`,
each miss is also looked up in a second classpath (the app's original system),
which separates "removed or changed upstream" from "never existed".

Inputs can be .apk/.jar (classes*.dex inside), bare .dex, or Android 9 .vdex
(version 019, standard or compact dex).

Usage:
  dex-api-check.py --target <dir|file>... [--baseline <dir|file>...]
                   [--lib <jar>...] <apk>...

A directory argument means every .jar/.vdex under it. Pure stdlib.
"""

import argparse
import io
import os
import struct
import sys
import zipfile

NO_INDEX = 0xFFFFFFFF


def uleb(buf, off):
    result = shift = 0
    while True:
        b = buf[off]
        off += 1
        result |= (b & 0x7F) << shift
        if b < 0x80:
            return result, off
        shift += 7


class Dex:
    """A standard dex, or an Android 9 compact dex inside a vdex.

    `base` is where the dex header starts in `buf`. Id tables are relative to
    it; string data, type lists and class data are relative to `data`, which
    for compact dex is the vdex's shared data section.
    """

    def __init__(self, buf, base=0, data=None):
        if buf[base:base + 4] not in (b"dex\n", b"cdex"):
            raise ValueError("not a dex")
        data = base if data is None else data
        u = lambda o: struct.unpack_from("<I", buf, base + o)[0]
        self.buf, self.data = buf, data
        n_str, o_str = u(0x38), u(0x3C)
        n_typ, o_typ = u(0x40), u(0x44)
        n_pro, o_pro = u(0x48), u(0x4C)
        n_fld, o_fld = u(0x50), u(0x54)
        n_met, o_met = u(0x58), u(0x5C)
        n_cls, o_cls = u(0x60), u(0x64)
        self.strings = [self._string(data + u(o_str + 4 * i)) for i in range(n_str)]
        self.types = [self.strings[u(o_typ + 4 * i)] for i in range(n_typ)]
        self.protos = []
        for i in range(n_pro):
            _, ret, params = struct.unpack_from("<III", buf, base + o_pro + 12 * i)
            self.protos.append("(" + "".join(self._type_list(params)) + ")" + self.types[ret])
        self.fields = []
        for i in range(n_fld):
            c, t, n = struct.unpack_from("<HHI", buf, base + o_fld + 8 * i)
            self.fields.append((self.types[c], self.strings[n], self.types[t]))
        self.methods = []
        for i in range(n_met):
            c, p, n = struct.unpack_from("<HHI", buf, base + o_met + 8 * i)
            self.methods.append((self.types[c], self.strings[n], self.protos[p]))
        self.classes = {}
        for i in range(n_cls):
            cls, _, sup, ifaces, _, _, cdata, _ = struct.unpack_from("<8I", buf, base + o_cls + 32 * i)
            meths, flds = set(), set()
            if cdata:
                off = data + cdata
                sf, off = uleb(buf, off)
                inf, off = uleb(buf, off)
                dm, off = uleb(buf, off)
                vm, off = uleb(buf, off)
                idx = 0
                for k in range(sf + inf):
                    if k == sf:
                        idx = 0
                    d, off = uleb(buf, off)
                    _, off = uleb(buf, off)
                    idx += d
                    _, name, typ = self.fields[idx]
                    flds.add((name, typ))
                idx = 0
                for k in range(dm + vm):
                    if k == dm:
                        idx = 0
                    d, off = uleb(buf, off)
                    _, off = uleb(buf, off)
                    _, off = uleb(buf, off)
                    idx += d
                    _, name, proto = self.methods[idx]
                    meths.add((name, proto))
            self.classes[self.types[cls]] = (
                None if sup == NO_INDEX else self.types[sup],
                self._type_list(ifaces),
                meths,
                flds,
            )

    def _string(self, off):
        _, off = uleb(self.buf, off)
        end = self.buf.index(b"\0", off)
        return self.buf[off:end].decode("utf-8", "replace")

    def _type_list(self, off):
        if not off:
            return []
        off += self.data
        n = struct.unpack_from("<I", self.buf, off)[0]
        return [self.types[struct.unpack_from("<H", self.buf, off + 4 + 2 * i)[0]] for i in range(n)]


def dex_blobs(path):
    if path.endswith(".vdex"):
        with open(path, "rb") as f:
            buf = f.read()
        if buf[:4] != b"vdex" or buf[4:8] != b"019\0":
            raise ValueError(f"{path}: unsupported vdex {buf[4:8]!r}")
        # magic, verifier-deps version, dex-section version ("000" = no dex),
        # dex count, deps size, per-dex checksums, then the dex section header
        # (dex size, shared data size, quickening size). Each dex is preceded
        # by a u4 quickening-table offset; shared data follows the last dex.
        if buf[8:12] == b"000\0":
            return
        n = struct.unpack_from("<I", buf, 12)[0]
        off = 20 + 4 * n
        dex_size = struct.unpack_from("<I", buf, off)[0]
        off += 12
        if not dex_size:
            return
        shared = off + dex_size
        for _ in range(n):
            off += 4
            size = struct.unpack_from("<I", buf, off + 0x20)[0]
            yield buf, off, shared if buf[off:off + 4] == b"cdex" else off
            off = (off + size + 3) & ~3
    elif path.endswith(".dex"):
        with open(path, "rb") as f:
            yield f.read(), 0, 0
    else:
        with zipfile.ZipFile(path) as z:
            for name in sorted(z.namelist()):
                if name.startswith("classes") and name.endswith(".dex"):
                    yield z.read(name), 0, 0


def expand(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in sorted(files):
                    if f.endswith((".jar", ".vdex")):
                        yield os.path.join(root, f)
        else:
            yield p


class ClassPath:
    def __init__(self, paths):
        self.classes = {}
        for p in expand(paths):
            for blob in dex_blobs(p):
                for k, v in Dex(*blob).classes.items():
                    self.classes.setdefault(k, v)


def ancestors(classes, cls):
    """cls, its superclasses and every superinterface that is defined."""
    seen, stack = [], [cls]
    while stack:
        c = stack.pop()
        if c in seen or c not in classes:
            continue
        seen.append(c)
        sup, ifaces, _, _ = classes[c]
        stack.extend(ifaces)
        if sup:
            stack.append(sup)
    return seen


def has_method(classes, cls, name, proto):
    chain = ancestors(classes, cls) + ["Ljava/lang/Object;"]
    return any(c in classes and (name, proto) in classes[c][2] for c in chain)


def has_field(classes, cls, name, typ):
    return any((name, typ) in classes[c][3] for c in ancestors(classes, cls))


def resolve(refs_m, refs_f, classes):
    for cls, name, proto in refs_m:
        if cls.startswith("["):
            continue
        if cls not in classes:
            yield "class", cls, ""
        elif not has_method(classes, cls, name, proto):
            yield "method", cls, name + proto
    for cls, name, typ in refs_f:
        if cls.startswith("["):
            continue
        if cls not in classes:
            yield "class", cls, ""
        elif not has_field(classes, cls, name, typ):
            yield "field", cls, name + ":" + typ


def check(apk, target, baseline, libs):
    own, refs_m, refs_f = {}, set(), set()
    for blob in dex_blobs(apk):
        d = Dex(*blob)
        own.update(d.classes)
        refs_m.update(d.methods)
        refs_f.update(d.fields)
    for p in libs:
        for blob in dex_blobs(p):
            for k, v in Dex(*blob).classes.items():
                own.setdefault(k, v)
    # Parent-first loading: a boot class shadows an app class of the same name.
    view = {**own, **target.classes}
    base = {**own, **baseline.classes} if baseline else None
    miss = []
    for kind, cls, member in sorted(set(resolve(refs_m, refs_f, view))):
        in_base = False
        if base is not None:
            if kind == "class":
                in_base = cls in base
            elif kind == "method":
                n, _, proto = member.partition("(")
                in_base = has_method(base, cls, n, "(" + proto)
            else:
                n, _, typ = member.partition(":")
                in_base = has_field(base, cls, n, typ)
        miss.append((kind, cls, member, in_base))
    return miss


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", nargs="+", required=True)
    ap.add_argument("--baseline", nargs="+")
    ap.add_argument("--lib", action="append", default=[])
    ap.add_argument("apks", nargs="+")
    a = ap.parse_args()
    target = ClassPath(a.target)
    baseline = ClassPath(a.baseline) if a.baseline else None
    print(f"target classes: {len(target.classes)}" +
          (f", baseline classes: {len(baseline.classes)}" if baseline else ""))
    worst = 0
    for apk in a.apks:
        miss = check(apk, target, baseline, a.lib)
        worst = max(worst, len(miss))
        print(f"== {os.path.basename(apk)}: {len(miss)} unresolved")
        for kind, cls, member, in_base in miss:
            tag = "" if baseline is None else ("  [in baseline]" if in_base else "  [not in baseline]")
            print(f"   {kind:6} {cls}{('->' + member) if member else ''}{tag}")
    sys.exit(1 if worst else 0)


if __name__ == "__main__":
    main()
