#!/usr/bin/env python3
"""Check whether Android-9 Sony libraries would link against a newer system.

For each input ELF, every undefined, non-weak dynamic symbol is looked up in the
transitive DT_NEEDED closure built from the target system's library directory.
Symbols that nothing in that closure defines are what a shim library would have
to provide. Missing DT_NEEDED entries are reported too.

Usage:
  abi-check.py --sysroot <dir with lib64/> [--extra <dir>] <elf>...

`--extra` adds directories searched after the sysroot, e.g. the Sony libraries
themselves when they depend on each other. Run with tools/capstone-venv
(pyelftools 0.31). Names are demangled with c++filt when it is on PATH.
"""

import argparse
import os
import shutil
import subprocess
import sys
from collections import deque

from elftools.elf.dynamic import DynamicSection
from elftools.elf.elffile import ELFFile

_cache = {}


def load(path):
    if path not in _cache:
        with open(path, "rb") as f:
            elf = ELFFile(f)
            needed, defined, undefined = [], set(), set()
            for sec in elf.iter_sections():
                if isinstance(sec, DynamicSection):
                    needed = [t.needed for t in sec.iter_tags() if t.entry.d_tag == "DT_NEEDED"]
            dynsym = elf.get_section_by_name(".dynsym")
            for sym in dynsym.iter_symbols() if dynsym else []:
                if not sym.name:
                    continue
                bind = sym["st_info"]["bind"]
                if sym["st_shndx"] == "SHN_UNDEF":
                    if bind != "STB_WEAK":
                        undefined.add(sym.name)
                else:
                    defined.add(sym.name.split("@")[0])
        _cache[path] = (needed, defined, undefined)
    return _cache[path]


def find(name, dirs):
    for d in dirs:
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return p
    return None


def demangle(names):
    if not names or not shutil.which("c++filt"):
        return list(names)
    out = subprocess.run(["c++filt"], input="\n".join(names), capture_output=True, text=True).stdout
    return out.splitlines()


def check(path, dirs):
    needed, _, undefined = load(path)
    seen, missing_libs, provided = set(), [], set()
    queue = deque(needed)
    while queue:
        lib = queue.popleft()
        if lib in seen:
            continue
        seen.add(lib)
        p = find(lib, dirs)
        if not p:
            missing_libs.append(lib)
            continue
        n, d, _ = load(p)
        provided |= d
        queue.extend(n)
    unresolved = sorted(s for s in undefined if s not in provided)
    return needed, missing_libs, unresolved


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sysroot", required=True)
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("elfs", nargs="+")
    a = ap.parse_args()
    dirs = [os.path.join(a.sysroot, "lib64"), a.sysroot] + a.extra
    total = 0
    for path in a.elfs:
        needed, missing_libs, unresolved = check(path, dirs)
        total += len(unresolved)
        print(f"== {os.path.basename(path)}: {len(unresolved)} unresolved, "
              f"{len(missing_libs)} missing libs, needs {' '.join(needed)}")
        for lib in missing_libs:
            print(f"   missing lib: {lib}")
        for raw, pretty in zip(unresolved, demangle(unresolved)):
            print(f"   {pretty}" + (f"    [{raw}]" if pretty != raw else ""))
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
