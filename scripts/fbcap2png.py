#!/usr/bin/env python3
"""Turn an fbcap recording into PNG frames plus an index (frame, us, fb id).

Usage: fbcap2png.py <fbcap.bin> <out-dir>
"""

import struct
import sys
from pathlib import Path

from PIL import Image


def main():
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    data = src.read_bytes()
    w, h = struct.unpack_from("<II", data, 0)
    size = w * h * 4
    pos, n, index = 16, 0, []
    while pos + 16 + size <= len(data):
        lo, hi, fb, _ = struct.unpack_from("<IIII", data, pos)
        img = Image.frombytes("RGBA", (w, h), data[pos + 16 : pos + 16 + size])
        img.convert("RGB").save(out / f"c{n:04d}.png")
        index.append(f"{n} {(hi << 32 | lo)} {fb}")
        pos += 16 + size
        n += 1
    (out / "index.txt").write_text("\n".join(index) + "\n")
    print(f"{n} frames {w}x{h}")


if __name__ == "__main__":
    main()
