#!/usr/bin/env python3
"""Check that prebuilt kernel modules will load into a rebuilt kernel.

Compares each module's vermagic with the kernel release and every entry of its
__versions table (CONFIG_MODVERSIONS symbol CRCs) with the new build's
Module.symvers. A CRC mismatch or a missing symbol makes insmod fail.

Usage: check-modversions.py <Module.symvers> <kernel-release> <module.ko>...
"""

import struct
import sys


def sections(elf):
    if elf[:4] != b"\x7fELF" or elf[4] != 2:
        raise ValueError("not a 64-bit ELF")
    shoff, = struct.unpack_from("<Q", elf, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", elf, 0x3A)
    hdrs = [struct.unpack_from("<IIQQQQIIQQ", elf, shoff + i * shentsize) for i in range(shnum)]
    strtab = hdrs[shstrndx]
    names = elf[strtab[4]:strtab[4] + strtab[5]]
    out = {}
    for h in hdrs:
        name = names[h[0]:names.index(b"\0", h[0])].decode()
        out[name] = elf[h[4]:h[4] + h[5]]
    return out


def main():
    symvers = {}
    for line in open(sys.argv[1]):
        crc, sym = line.split("\t")[:2]
        symvers[sym] = int(crc, 16)
    release = sys.argv[2]
    bad = 0
    for path in sys.argv[3:]:
        sec = sections(open(path, "rb").read())
        info = dict(
            kv.split("=", 1) for kv in sec[".modinfo"].decode(errors="replace").split("\0") if "=" in kv
        )
        magic = info.get("vermagic", "")
        ok_magic = magic.split(" ")[0] == release
        vers = sec.get("__versions", b"")
        miss, diff = [], []
        for i in range(0, len(vers), 64):
            crc, = struct.unpack_from("<Q", vers, i)
            name = vers[i + 8:i + 64].split(b"\0", 1)[0].decode()
            if name not in symvers:
                miss.append(name)
            elif symvers[name] != crc & 0xFFFFFFFF:
                diff.append(name)
        n = len(vers) // 64
        status = "OK" if ok_magic and not miss and not diff else "FAIL"
        bad += status != "OK"
        print(f"{status} {path}: vermagic '{magic}', {n} symbols, {len(miss)} missing, {len(diff)} CRC mismatches")
        for name in miss[:20]:
            print(f"   missing {name}")
        for name in diff[:20]:
            print(f"   crc     {name}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
