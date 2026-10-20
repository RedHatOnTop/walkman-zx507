#!/usr/bin/env python3
"""Compare tagcharset-test output from the unit with a TagSim variant.

Usage: compare-device.py <tagsim.jsonl> <variant> <device-out.txt>
"""
import json
import sys

sim = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
variant = sys.argv[2]
dev, cur = [], None
for line in open(sys.argv[3], encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("#"):
        cur = {}
        dev.append(cur)
    else:
        name, value = line.split("\t")
        cur[name] = bytes.fromhex(value).decode("utf-8", "surrogateescape")
assert len(dev) == len(sim), (len(dev), len(sim))
same = diff = 0
for j, d in zip(sim, dev):
    s = j[variant]["out"]
    for name in sorted(set(s) | set(d)):
        if s.get(name) == d.get(name):
            same += 1
        else:
            diff += 1
            print(f"{name:11} sim={s.get(name)!r:45} unit={d.get(name)!r:45} {j['path'].rsplit('/', 1)[-1][:40]}")
print(f"{variant}: {same} same, {diff} different")
