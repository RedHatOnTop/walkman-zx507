#!/usr/bin/env python3
"""Point W.music's libspmedia_walkman.so at libwmtrackshim.so for AudioTrack.

Renames the eight android::AudioTrack imports to android::WmShimTrck and the
libaudioclient.so DT_NEEDED to libwmtrackshim.so. Both new names have the
same length as the old ones, so .dynstr keeps its layout and nothing else
moves. Imports are not in .gnu.hash, and the shim itself needs
libaudioclient.so, so AudioSystem::getParameters still resolves.

Only the 4.06.00 build is patched (sha256 checked). The input is the unit's
own file; the output stays on this machine.

Usage: patch-spmedia.py <libspmedia_walkman.so> <out.so>
"""

import hashlib
import struct
import sys

SHA256 = "2eca940e7f58f0c001eb83481d6bc9a31648dda863c3b674bce7758c760228ad"
OLD_CLASS, NEW_CLASS = b"_ZN7android10AudioTrack", b"_ZN7android10WmShimTrck"
OLD_NEEDED, NEW_NEEDED = b"libaudioclient.so", b"libwmtrackshim.so"
IMPORTS = 8

DT_NULL, DT_NEEDED, DT_STRTAB, DT_SYMTAB, DT_STRSZ = 0, 1, 5, 6, 10
DT_SONAME, DT_RUNPATH, DT_VERNEED, DT_VERNEEDNUM = 14, 29, 0x6FFFFFFE, 0x6FFFFFFF


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, "rb").read())
    if hashlib.sha256(data).hexdigest() != SHA256:
        sys.exit(f"{src}: unexpected sha256, not the 4.06.00 libspmedia_walkman.so")

    phoff, = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    loads, dynamic = [], None
    for i in range(phnum):
        p_type, _, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<IIQQQQ", data, phoff + i * phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dynamic = (p_offset, p_filesz)

    def off(vaddr):
        for v, o, sz in loads:
            if v <= vaddr < v + sz:
                return vaddr - v + o
        sys.exit(f"vaddr {vaddr:#x} not in a PT_LOAD")

    dyn, refs = {}, []
    for pos in range(dynamic[0], dynamic[0] + dynamic[1], 16):
        tag, val = struct.unpack_from("<qQ", data, pos)
        if tag == DT_NULL:
            break
        if tag in (DT_NEEDED, DT_SONAME, DT_RUNPATH):
            refs.append(val)
        dyn.setdefault(tag, []).append(val)
    strtab, strsz = off(dyn[DT_STRTAB][0]), dyn[DT_STRSZ][0]
    symtab = off(dyn[DT_SYMTAB][0])
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    symsz = None
    for i in range(shnum):
        sh_type, _, _, sh_offset, sh_size = struct.unpack_from("<IQQQQ", data, shoff + i * shentsize + 4)
        if sh_type == 11 and sh_offset == symtab:  # SHT_DYNSYM
            symsz = sh_size
    if symsz is None:
        sys.exit("no .dynsym section header at DT_SYMTAB")

    def name(o):
        return bytes(data[strtab + o : data.index(0, strtab + o)])

    imports = []
    for pos in range(symtab, symtab + symsz, 24):
        st_name, _, _, st_shndx = struct.unpack_from("<IBBH", data, pos)
        refs.append(st_name)
        if st_shndx == 0 and name(st_name).startswith(OLD_CLASS):
            imports.append(st_name)
    if DT_VERNEED in dyn:
        vn = off(dyn[DT_VERNEED][0])
        for _ in range(dyn[DT_VERNEEDNUM][0]):
            _, cnt, file_, aux, nxt = struct.unpack_from("<HHIII", data, vn)
            refs.append(file_)
            va = vn + aux
            for _ in range(cnt):
                _, _, _, vna_name, vna_next = struct.unpack_from("<IHHII", data, va)
                refs.append(vna_name)
                va += vna_next
            vn += nxt

    needed = [o for o in dyn[DT_NEEDED] if name(o) == OLD_NEEDED]
    if len(imports) != IMPORTS or len(needed) != 1:
        sys.exit(f"found {len(imports)} AudioTrack imports and {len(needed)} {OLD_NEEDED.decode()} entries")
    for start in imports + needed:
        end = start + len(name(start))
        shared = [r for r in refs if start < r < end]
        if shared:
            sys.exit(f"string at {start:#x} is shared with references {shared}")

    for o in imports:
        data[strtab + o : strtab + o + len(OLD_CLASS)] = NEW_CLASS
    o = needed[0]
    data[strtab + o : strtab + o + len(OLD_NEEDED)] = NEW_NEEDED
    assert strtab + strsz <= len(data)
    open(dst, "wb").write(data)
    print(f"{dst}: {len(imports)} imports renamed, DT_NEEDED {OLD_NEEDED.decode()} -> {NEW_NEEDED.decode()}")


if __name__ == "__main__":
    main()
