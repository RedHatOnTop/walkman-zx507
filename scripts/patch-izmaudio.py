#!/usr/bin/env python3
"""Let IzmAudioManager pick its output when Android 13 already knows the jack.

IzmAudioManager.updateConnected() reads the codec's jack status, and when the
wired state changed it calls AudioManager.setWiredDeviceConnectionState(8, ...)
and returns false: on Android 9 AudioService answered with a second
HEADSET_PLUG broadcast, and that one ran updateOutput(). On the GSI,
AudioService has already connected the headphone from the jack's input event
(persist.sys.overlay.devinputjack), so the call changes nothing, no broadcast
follows, and the output stays HEADSET_NONE. The HAL then keeps
izm_output_device=none and never opens a PCM: no sound.

The patch turns that `const/4 v0, 0` into `const/4 v0, 1`, so the method
returns true on that path as well and the caller runs updateOutput() at once.
A second broadcast, where one still comes, finds the output unchanged.

Only the classes.dex that add-sony-apps.sh builds from the 4.06.00 APK is
patched (sha256 checked). Input and output stay on this machine.

Usage: patch-izmaudio.py <IzmAudioManager.apk> <out-unsigned.apk>
"""

import hashlib
import struct
import sys
import zipfile
import zlib

SHA256 = "e921bdcb22e2148c89eeb8b2b73c7da3233c9737e6e5d7147147783c09a1e873"
# IzmAudioManager.updateConnected(IZ)Z, from dexlib2:
#   invoke-virtual AudioManager.setWiredDeviceConnectionState(IILString;LString;)V
#   iput-boolean mConnectedWiredHeadphone
#   const/4 v0, 0
#   goto
SITE = 0x1E1CBE
OLD = bytes.fromhex("6e5ec105c7d05c1becb212002802")
NEW = bytes.fromhex("6e5ec105c7d05c1becb212102802")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(src) as z:
        dex = bytearray(z.read("classes.dex"))
        if hashlib.sha256(dex).hexdigest() != SHA256:
            sys.exit(f"{src}: unexpected classes.dex sha256")
        if dex[SITE:SITE + len(OLD)] != OLD:
            sys.exit(f"{src}: patch site does not match")
        dex[SITE:SITE + len(NEW)] = NEW
        dex[12:32] = hashlib.sha1(dex[32:]).digest()
        struct.pack_into("<I", dex, 8, zlib.adler32(dex[12:]))

        with zipfile.ZipFile(dst, "w") as out:
            for info in z.infolist():
                if info.filename.startswith("META-INF/"):
                    continue
                data = bytes(dex) if info.filename == "classes.dex" else z.read(info)
                out.writestr(info, data, compress_type=info.compress_type)


if __name__ == "__main__":
    main()
