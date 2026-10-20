#!/usr/bin/env python3
"""Disassemble AArch64 functions from an Android ELF with call and string context.

Resolves PLT stubs to imported symbol names, ADRP+ADD/LDR pairs to the C
strings they point at, and BL targets to local symbol names, so a Sony blob
can be read without a full RE suite.

Usage:
  disasm.py <elf> --list <regex>          # list defined functions matching regex
  disasm.py <elf> <regex> [--max N]        # disassemble matching functions
  disasm.py <elf> --addr 0x1234 --len 256  # disassemble a raw range

Run with the venv in tools/capstone-venv (capstone 5.0.6, pyelftools 0.31).
Symbol names are demangled with c++filt when it is on PATH.
"""

import argparse
import re
import shutil
import subprocess
import sys

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
from elftools.elf.elffile import ELFFile
from elftools.elf.relocation import RelocationSection


def demangle(names):
    if not names or not shutil.which("c++filt"):
        return {n: n for n in names}
    out = subprocess.run(["c++filt"], input="\n".join(names), capture_output=True, text=True).stdout
    return dict(zip(names, out.splitlines()))


class Image:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.elf = ELFFile(self.f)
        if self.elf["e_machine"] != "EM_AARCH64":
            sys.exit(f"{path}: not AArch64 ({self.elf['e_machine']})")
        self.segments = [s for s in self.elf.iter_segments() if s["p_type"] == "PT_LOAD"]
        self.funcs = {}
        for name in (".dynsym", ".symtab"):
            sec = self.elf.get_section_by_name(name)
            if not sec:
                continue
            for sym in sec.iter_symbols():
                if sym["st_info"]["type"] == "STT_FUNC" and sym["st_shndx"] != "SHN_UNDEF" and sym["st_value"]:
                    self.funcs.setdefault(sym["st_value"], (sym.name, sym["st_size"]))
        self.plt = self._plt_map()
        self.names = demangle(sorted({n for n, _ in self.funcs.values()} | set(self.plt.values())))

    def read(self, addr, size):
        for seg in self.segments:
            if seg["p_vaddr"] <= addr < seg["p_vaddr"] + seg["p_filesz"]:
                self.f.seek(seg["p_offset"] + addr - seg["p_vaddr"])
                return self.f.read(min(size, seg["p_vaddr"] + seg["p_filesz"] - addr))
        return b""

    def cstring(self, addr):
        raw = self.read(addr, 256)
        end = raw.find(b"\0")
        if end <= 0:
            return None
        s = raw[:end]
        if all(32 <= c < 127 or c in (9, 10) for c in s):
            return s.decode()
        return None

    def _plt_map(self):
        got = {}
        for sec in self.elf.iter_sections():
            if isinstance(sec, RelocationSection) and sec.name in (".rela.plt", ".rel.plt"):
                symtab = self.elf.get_section(sec["sh_link"])
                for rel in sec.iter_relocations():
                    got[rel["r_offset"]] = symtab.get_symbol(rel["r_info_sym"]).name
        plt = self.elf.get_section_by_name(".plt")
        if not plt:
            return {}
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        stubs, page, start = {}, None, None
        for ins in md.disasm(plt.data(), plt["sh_addr"]):
            if ins.mnemonic == "adrp" and ins.op_str.startswith("x16"):
                page, start = int(ins.op_str.split("#")[1], 16), ins.address
            elif ins.mnemonic == "ldr" and ins.op_str.startswith("x17") and page is not None:
                m = re.search(r"#(0x[0-9a-f]+)\]", ins.op_str)
                slot = page + (int(m.group(1), 16) if m else 0)
                if slot in got:
                    stubs[start] = got[slot]
        return stubs

    def label(self, addr):
        if addr in self.plt:
            return self.names.get(self.plt[addr], self.plt[addr]) + "@plt"
        if addr in self.funcs:
            n = self.funcs[addr][0]
            return self.names.get(n, n)
        return None

    def disasm(self, addr, size, out):
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        regs = {}
        for ins in md.disasm(self.read(addr, size), addr):
            note = ""
            ops = ins.op_str
            if ins.mnemonic == "adrp":
                r, imm = ops.split(", #")
                regs[r] = int(imm, 16)
            elif ins.mnemonic == "add" and re.match(r"(x\d+), (x\d+), #0x[0-9a-f]+$", ops):
                dst, src, imm = re.match(r"(x\d+), (x\d+), #(0x[0-9a-f]+)$", ops).groups()
                if src in regs:
                    target = regs[src] + int(imm, 16)
                    regs[dst] = target
                    s = self.cstring(target)
                    note = f'"{s}"' if s is not None else (self.label(target) or hex(target))
            elif ins.mnemonic in ("ldr", "ldrsw") and re.match(r"[xw]\d+, \[(x\d+), #0x[0-9a-f]+\]$", ops):
                base, imm = re.search(r"\[(x\d+), #(0x[0-9a-f]+)\]", ops).groups()
                if base in regs:
                    note = f"[{hex(regs[base] + int(imm, 16))}]"
            elif ins.mnemonic in ("bl", "b") and ops.startswith("#"):
                target = int(ops[1:], 16)
                note = self.label(target) or ""
            out.write(f"  {ins.address:08x}  {ins.mnemonic:<7} {ops:<40} {note}\n".rstrip() + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("pattern", nargs="?")
    ap.add_argument("--list", metavar="REGEX")
    ap.add_argument("--addr", type=lambda v: int(v, 0))
    ap.add_argument("--len", type=lambda v: int(v, 0), default=256)
    ap.add_argument("--max", type=int, default=5)
    a = ap.parse_args()
    img = Image(a.elf)
    if a.addr is not None:
        img.disasm(a.addr, a.len, sys.stdout)
        return
    rx = re.compile(a.list or a.pattern or ".")
    hits = sorted((addr, name, size) for addr, (name, size) in img.funcs.items()
                  if rx.search(img.names.get(name, name)) or rx.search(name))
    if a.list:
        for addr, name, size in hits:
            print(f"{addr:08x} {size:6d} {img.names.get(name, name)}")
        return
    for addr, name, size in hits[: a.max]:
        print(f"== {img.names.get(name, name)} @ {addr:#x} ({size} bytes)")
        img.disasm(addr, size or 256, sys.stdout)
    if len(hits) > a.max:
        print(f"({len(hits) - a.max} more matches; raise --max)")


if __name__ == "__main__":
    main()
