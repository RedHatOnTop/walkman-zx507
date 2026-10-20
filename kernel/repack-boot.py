#!/usr/bin/env python3
"""Swap the kernel in an Android boot image (header v0/v1), keeping the rest.

The ramdisk, cmdline, load addresses and the tail of the partition (AVB footer)
come from the stock image; only the kernel and the header's sizes and id change.
The output has the stock image's size, so it can be flashed as a whole
partition.

Usage: repack-boot.py <stock-boot.img> <new-Image> <out.img>
"""

import hashlib
import struct
import sys


def pages(n, page):
    return (n + page - 1) // page * page


def main():
    stock = open(sys.argv[1], "rb").read()
    kernel = open(sys.argv[2], "rb").read()
    if stock[:8] != b"ANDROID!":
        sys.exit("not an Android boot image")
    ks, ka, rs, ra, ss, sa, ta, page, hv, osv = struct.unpack_from("<10I", stock, 8)
    if hv > 1:
        sys.exit(f"header v{hv} not handled")
    if hv == 1:
        dtbo_size, dtbo_off, hdr_size = struct.unpack_from("<IQI", stock, 1632)
        if dtbo_size:
            sys.exit("recovery_dtbo present, not handled")

    off = page
    old_kernel = stock[off:off + ks]
    off += pages(ks, page)
    ramdisk = stock[off:off + rs]
    off += pages(rs, page)
    second = stock[off:off + ss]
    off += pages(ss, page)
    end_of_stock_payload = off

    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    if hv == 1:
        sha.update(b"")
        sha.update(struct.pack("<I", 0))
    digest = sha.digest() + b"\0" * 12

    header = bytearray(stock[:page])
    struct.pack_into("<I", header, 8, len(kernel))
    header[576:608] = digest

    out = bytearray(header)
    out += kernel + b"\0" * (pages(len(kernel), page) - len(kernel))
    out += ramdisk + b"\0" * (pages(rs, page) - rs)
    out += second + b"\0" * (pages(ss, page) - ss)
    if len(out) > len(stock) - 64:
        sys.exit(f"new image ({len(out)} bytes) does not fit the partition")
    # Zero the stale payload, keep the partition tail (AVB footer) as it was.
    tail = stock[max(len(out), end_of_stock_payload):]
    out += b"\0" * (len(stock) - len(out) - len(tail)) + tail
    assert len(out) == len(stock)
    open(sys.argv[3], "wb").write(out)
    print(f"kernel {len(old_kernel)} -> {len(kernel)} bytes, image {len(out)} bytes")


if __name__ == "__main__":
    main()
