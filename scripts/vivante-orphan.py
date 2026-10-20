#!/usr/bin/env python3
"""Make the Vivante GLES driver orphan a buffer on glBufferData(NULL).

Skia (hwui) streams vertices with glBufferData(target, size, NULL) followed by
glBufferSubData(0, n). On the ZX507's vendor libGLESv2_VIVANTE.so (6.2.4.p4),
__glChipBufferData ignores a NULL respecification of the same size, so the
following gcoBUFOBJ_Upload finds a buffer the GPU still reads and waits on its
fence, polling with usleep. Every flush then waits for the GPU to finish the
previous one, so RenderThread and the GPU never overlap (devlog 2026-10-15).

The patch sends the NULL case down the driver's own path for a new buffer
object, gcoBUFOBJ_Upload(bo, NULL, 0, size), which allocates a fresh node and
frees the old one through the driver's deferred release. That is what GL
specifies for glBufferData with NULL data: the old contents are undefined.

One instruction at 0x87d2c, `mov w25, wzr` -> `b 0x87da0`. Only the exact
4.06.00 vendor build is patched (sha256 checked); the library itself is
Sony/NXP's and is never kept in this repository.

Usage: scripts/vivante-orphan.py <libGLESv2_VIVANTE.so> <out.so>
"""
import hashlib
import struct
import sys

SHA256 = "a843eecd756e9e4bd3daa3299b2d368021641be27e2253c4aed833d90d5d43d1"
LOAD_BIAS = 0x10000  # first PT_LOAD: offset 0 at vaddr 0x10000
SITE = 0x87D2C
EXPECT = {SITE - 4: 0xB50002B3, SITE: 0x2A1F03F9}  # cbnz x19, 87d7c; mov w25, wzr
TARGET = 0x87DA0  # gcoBUFOBJ_Upload(bo, NULL, 0, size, usage)

src, out = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
if hashlib.sha256(data).hexdigest() != SHA256:
    sys.exit(f"{src}: not the 4.06.00 libGLESv2_VIVANTE.so")
for vaddr, word in EXPECT.items():
    off = vaddr - LOAD_BIAS
    if struct.unpack_from("<I", data, off)[0] != word:
        sys.exit(f"{src}: unexpected instruction at {vaddr:#x}")
struct.pack_into("<I", data, SITE - LOAD_BIAS, 0x14000000 | (TARGET - SITE) // 4)
open(out, "wb").write(data)
print(f"{out}: {hashlib.sha256(data).hexdigest()}")
