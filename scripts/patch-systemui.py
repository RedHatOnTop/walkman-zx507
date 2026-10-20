#!/usr/bin/env python3
"""Cut two GPU costs out of the GSI's SystemUI (devlog 2026-10-16).

1. LightRevealScrim stops drawing once it is fully revealed.

   LightRevealScrim covers the whole NotificationShade window. Its onDraw()
   only returns early when revealAmount == 0:

       if (canvas == null || revealGradientWidth <= 0 || revealGradientHeight <= 0
               || revealAmount == 0f) {
           if (revealAmount < 1f) canvas?.drawColor(revealGradientEndColor)
           return
       }
       ...
       canvas.drawRect(0f, 0f, width, height, gradientPaint)

   so in the normal unlocked state (revealAmount 1, gradient fully
   transparent) every shade and QS frame still blends a full-screen gradient
   rect. On the ZX507's GC7000NanoUltra that is one of the two full-screen
   layers the hwui overdraw view shows, about 3.9 ms of GPU per frame at
   720x1280. The patch also takes the early return when revealAmount >= 1,
   where the existing `revealAmount < 1f` test then skips drawColor, so
   nothing is drawn. Partial reveals (screen on/off animations) are unchanged.

   onDraw insns 0x000f-0x001a (12 code units) become:

       iget v0, v8, revealAmount
       const/high16 v2, 1.0f        # v2 is first written at 0x001d otherwise
       cmpl-float v2, v0, v2
       if-gez v2, 0x0058
       cmpl-float v0, v0, v1        # v1 is 0.0f
       if-eqz v0, 0x0058

2. QSFooterView never shows the build number.

   With developer options on, setBuildText() fills the footer's build text
   and selects it, so it marquees with fading edges. Each fading edge is a
   saveBehind, which the Vivante driver serves as a CPU copy after draining
   the GPU, on every QS frame. Hidden, QS expand and collapse missed 36
   vsyncs instead of 45 at 540x960. The test at insn 0x003d becomes a goto
   to the developer-options-off branch (0x0060), plus a nop.

Only TrebleDroid's ci-20230905 SystemUI.apk is patched (classes.dex sha256
checked). The output is unsigned; sign it with the platform key, which is the
key the GSI signed SystemUI with.

Usage: patch-systemui.py <SystemUI.apk> <out-unsigned.apk>
"""

import hashlib
import struct
import sys
import zipfile
import zlib

DEX = "classes.dex"
SHA256 = "7ab87b780226f82047e92eeeaf56150d6760c518cb8e2606809ae521443450db"
PATCHES = [
    # LightRevealScrim.onDraw insns 0x4f1310 + 0x000f units
    (0x4F132E,
     bytes.fromhex("5280ed78" "2e000001" "39000400" "1210" "2802" "1200" "38000300" "283e"),
     bytes.fromhex("5280ed78" "1502803f" "2d020002" "3b024300" "2d000001" "38003f00")),
    # QSFooterView.setBuildText insns 0x47e918 + 0x003d units
    (0x47E992, bytes.fromhex("38002300"), bytes.fromhex("2823" "0000")),
]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(src) as z:
        dex = bytearray(z.read(DEX))
        if hashlib.sha256(dex).hexdigest() != SHA256:
            sys.exit(f"{src}: unexpected {DEX} sha256")
        for site, old, new in PATCHES:
            if dex[site:site + len(old)] != old:
                sys.exit(f"{src}: patch site {site:#x} does not match")
            dex[site:site + len(new)] = new
        dex[12:32] = hashlib.sha1(dex[32:]).digest()
        struct.pack_into("<I", dex, 8, zlib.adler32(dex[12:]))

        with zipfile.ZipFile(dst, "w") as out:
            for info in z.infolist():
                if info.filename.startswith("META-INF/"):
                    continue
                data = bytes(dex) if info.filename == DEX else z.read(info)
                out.writestr(info, data, compress_type=info.compress_type)


if __name__ == "__main__":
    main()
