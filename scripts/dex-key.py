#!/usr/bin/env python3
"""Print a key for a jar's code: sha256 over its classes*.dex entries, in order.

ART accepts an odex/vdex only for the exact dex bytes it was compiled from, so
compiled artifacts are cached under this key (scripts/services-odex.sh) and
looked up by it (scripts/izm-audio.sh). Zip metadata does not change it.

Usage: dex-key.py <file.jar>
"""

import hashlib
import re
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as z:
    names = sorted((n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)),
                   key=lambda n: int(n[7:-4] or 1))
    h = hashlib.sha256()
    for n in names:
        h.update(n.encode() + b"\0" + z.read(n))
print(h.hexdigest()[:16])
