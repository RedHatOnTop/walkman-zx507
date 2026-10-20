#!/usr/bin/env bash
# dis.sh <lib> <syms> <start> <stop>: disassemble with local symbol names on branch targets.
B=~/Android/sdk/ndk/21.4.7075529/toolchains/llvm/prebuilt/linux-x86_64/bin
$B/aarch64-linux-android-objdump -d --start-address=$3 --stop-address=$4 $1 | grep -vE '^\s*$' | awk '{ $1=$1; print }' | cut -c1-110 | python3 -c '
import sys, re, bisect
syms = []
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) == 3: syms.append((int(p[0], 16), p[2]))
syms.sort(); addrs = [a for a, _ in syms]
def name(a):
    i = bisect.bisect_right(addrs, a) - 1
    return f"{syms[i][1]}+{a-syms[i][0]:#x}" if i >= 0 else hex(a)
for l in sys.stdin:
    m = re.search(r"\b(bl|b|b\.\w+|cbz|cbnz|tbz|tbnz)\s+(?:\w+,\s*)*(?:#\d+,\s*)?([0-9a-f]+) <", l)
    if m and "@plt" not in l:
        l = l.rstrip() + "   ; " + name(int(m.group(2), 16))
    print(l.rstrip())
' $2
