#!/usr/bin/env python3
"""Rewrite an APK's px dimensions as dp, so Sony's UI follows the render size.

Sony laid out the ZX507's own apps (W.music, the volume dial, sound
settings, the volume alert) in pixels of its 720x1280 panel. Rendered at any
other size, such as `wm size 540x960`, their grids run off the right edge
(devlog 2026-10-17). Every TYPE_DIMENSION value with unit
px, in the compiled XML under res/ and in resources.arsc (plain entries and
style bags), becomes px * 160 / 360 dp. The GSI runs the panel at 360 dpi,
so at 720x1280 the result is the same pixels as before; at other sizes it
keeps Sony's proportions. Zero stays zero. The code is left alone: anything
the app sizes in pixels from Java is not covered, and at 540x960 that leaves
W.music's library grid (LibraryTopGridView's 342x162 icons) and the volume
dial broken, so the images keep the display at 720x1280.

The output is unsigned; sign it with the key the image's copy was signed
with (the AOSP platform test key, see add-sony-apps.sh).

Usage: px-to-dp.py <in.apk> <out-unsigned.apk>
"""

import struct
import sys
import zipfile

BASE_DPI = 360
TYPE_DIMENSION = 0x05
UNIT_PX, UNIT_DIP = 0, 1
RADIX_SHIFT = [0, 7, 15, 23]  # 23p0, 16p7, 8p15, 0p23


def to_float(data):
    mantissa = struct.unpack("<i", struct.pack("<I", data & 0xFFFFFF00))[0] >> 8
    return mantissa / (1 << RADIX_SHIFT[(data >> 4) & 3])


def to_complex(value, unit):
    for radix in (3, 2, 1, 0):  # the finest radix the mantissa still fits in
        m = round(value * (1 << RADIX_SHIFT[radix]))
        if -(1 << 23) <= m < (1 << 23):
            return ((m & 0xFFFFFF) << 8) | (radix << 4) | unit
    raise ValueError(value)


def convert(buf, off):
    """Rewrite the Res_value at off if it is a px dimension; return 1 if it was."""
    size, _, dtype, data = struct.unpack_from("<HBBI", buf, off)
    if size != 8 or dtype != TYPE_DIMENSION or data & 0xF != UNIT_PX:
        return 0
    px = to_float(data)
    struct.pack_into("<I", buf, off + 4, to_complex(px * 160 / BASE_DPI, UNIT_DIP))
    return 1


def xml(buf):
    n = 0
    pos = struct.unpack_from("<HHI", buf, 0)[1]
    while pos < len(buf):
        ctype, hsize, csize = struct.unpack_from("<HHI", buf, pos)
        if ctype == 0x0102:  # RES_XML_START_ELEMENT_TYPE
            ext = pos + hsize
            start, asize, count = struct.unpack_from("<HHH", buf, ext + 8)
            for i in range(count):
                n += convert(buf, ext + start + i * asize + 12)
        pos += csize
    return n


def arsc(buf):
    n = 0
    pos = struct.unpack_from("<HHI", buf, 0)[1]
    while pos < len(buf):
        ctype, hsize, csize = struct.unpack_from("<HHI", buf, pos)
        if ctype == 0x0200:  # RES_TABLE_PACKAGE_TYPE: walk its chunks
            p = pos + hsize
            while p < pos + csize:
                t, h, c = struct.unpack_from("<HHI", buf, p)
                if t == 0x0201:  # RES_TABLE_TYPE_TYPE
                    flags = buf[p + 9]
                    count, entries = struct.unpack_from("<II", buf, p + 12)
                    for i in range(count):
                        if flags & 0x01:  # FLAG_SPARSE: (idx, offset / 4) pairs
                            eoff = struct.unpack_from("<H", buf, p + h + i * 4 + 2)[0] * 4
                        else:
                            eoff = struct.unpack_from("<I", buf, p + h + i * 4)[0]
                            if eoff == 0xFFFFFFFF:
                                continue
                        e = p + entries + eoff
                        esize, eflags = struct.unpack_from("<HH", buf, e)
                        if eflags & 0x0001:  # FLAG_COMPLEX: a bag of (name, Res_value)
                            mcount = struct.unpack_from("<I", buf, e + 12)[0]
                            for k in range(mcount):
                                n += convert(buf, e + esize + k * 12 + 4)
                        else:
                            n += convert(buf, e + esize)
                p += c
        pos += csize
    return n


def main():
    src, dst = sys.argv[1], sys.argv[2]
    total = 0
    with zipfile.ZipFile(src) as z, zipfile.ZipFile(dst, "w") as out:
        for info in z.infolist():
            if info.filename.startswith("META-INF/"):
                continue
            data = z.read(info)
            if info.filename == "resources.arsc":
                buf = bytearray(data)
                n = arsc(buf)
                data = bytes(buf)
            elif info.filename.startswith("res/") and info.filename.endswith(".xml") \
                    and data[:2] == b"\x03\x00":
                buf = bytearray(data)
                n = xml(buf)
                data = bytes(buf)
            else:
                n = 0
            if n:
                print(f"{n:5d} {info.filename}")
            total += n
            out.writestr(info, data, compress_type=info.compress_type)
    print(f"{total:5d} px values -> dp")


if __name__ == "__main__":
    main()
