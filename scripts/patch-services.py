#!/usr/bin/env python3
"""Let global keys marked dispatchWhenNonInteractive work with the screen off.

PhoneWindowManager.interceptKeyBeforeQueueing() dispatches a global key from
the non-interactive state only if it is a wake key, and only its key-down:

    if (!interactive && isWakeKey && down
            && mGlobalKeyManager.shouldDispatchFromNonInteractive(keyCode)) {
        mGlobalKeyManager.setBeganFromNonInteractive();
        result = ACTION_PASS_TO_USER;
        ...
    }
    if (isWakeKey) wakeUpFromWakeKey(event);
    return result;

The ZX507's volume keys are not wake keys, so with the screen off they were
dropped before VolumeCtrlPanelApp saw them. Sony's Android 9 framework sent
them anyway, without waking the screen. The patch drops the isWakeKey and
down tests (two if-eqz become nops): key-down and key-up both reach the
receiver, whose state needs the key-up, and wakeUpFromWakeKey() still runs
only for real wake keys. Keys without dispatchWhenNonInteractive in
global_keys.xml behave as before.

Only TrebleDroid's ci-20230905 services.jar is patched (classes2.dex sha256
checked). Its odex no longer matches afterwards and has to go.

Usage: patch-services.py <services.jar> <out.jar>
"""

import hashlib
import struct
import sys
import zipfile
import zlib

DEX = "classes2.dex"
SHA256 = "dd9ee6771d3f167cc0407914d24f596226be8298410759d1b0fe49552c7279de"
# interceptKeyBeforeQueueing(Landroid/view/KeyEvent;I)I, from dexlib2:
#   if-nez v8 (interactive); if-eqz v7 (isWakeKey); if-eqz v4 (down)
SITE = 0x21F9E8
OLD = bytes.fromhex("39081700" "38071500" "38041300")
NEW = bytes.fromhex("39081700" "00000000" "00000000")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(src) as z:
        dex = bytearray(z.read(DEX))
        if hashlib.sha256(dex).hexdigest() != SHA256:
            sys.exit(f"{src}: unexpected {DEX} sha256")
        if dex[SITE:SITE + len(OLD)] != OLD:
            sys.exit(f"{src}: patch site does not match")
        dex[SITE:SITE + len(NEW)] = NEW
        dex[12:32] = hashlib.sha1(dex[32:]).digest()
        struct.pack_into("<I", dex, 8, zlib.adler32(dex[12:]))

        with zipfile.ZipFile(dst, "w") as out:
            for info in z.infolist():
                data = bytes(dex) if info.filename == DEX else z.read(info)
                out.writestr(info, data, compress_type=info.compress_type)


if __name__ == "__main__":
    main()
