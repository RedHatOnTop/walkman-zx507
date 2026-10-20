#!/usr/bin/env python3
"""Pull the debug GSI's boot logs over its USB ECM gadget (gsi-debug/init.sh).

Polls http://192.168.77.1/ and keeps the newest full copy of each log per boot.
A boot is told apart by its boot_id, so a reboot loop leaves one set of files
per attempt. Connection changes go to events.log with host wall-clock times.

Usage: gsi-netlog.py <out-dir> [seconds]
"""

import os
import sys
import time
import urllib.error
import urllib.request

HOST = "http://192.168.77.1/"
FAST = ["kmsg.log"]
SLOW = ["logcat.log", "logcat.err", "ps.log"]

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def get(name):
    try:
        with opener.open(HOST + name, timeout=1.5) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        return None if e.code == 404 else b""
    except (OSError, urllib.error.URLError):
        return b""


def main():
    out = sys.argv[1]
    limit = float(sys.argv[2]) if len(sys.argv) > 2 else 1800
    os.makedirs(out, exist_ok=True)
    events = open(os.path.join(out, "events.log"), "a", buffering=1)

    def note(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        events.write(line + "\n")
        print(line, flush=True)

    boots = {}
    up = False
    last_slow = 0.0
    end = time.monotonic() + limit
    note(f"polling {HOST} for {limit:.0f} s")
    while time.monotonic() < end:
        boot_id = get("boot_id")
        kmsg = get("kmsg.log") if boot_id else b""
        if not kmsg:
            if up:
                note("lost")
                up = False
            time.sleep(0.5)
            continue
        key = boot_id.strip()
        if key not in boots:
            boots[key] = len(boots) + 1
            note(f"boot {boots[key]} seen: {key.decode(errors='replace')}")
        n = boots[key]
        if not up:
            note(f"connected (boot {n}, kmsg {len(kmsg)} bytes)")
            up = True
        with open(os.path.join(out, f"boot{n:02d}-kmsg.log"), "wb") as f:
            f.write(kmsg)
        if time.monotonic() - last_slow > 2:
            last_slow = time.monotonic()
            for name in SLOW:
                data = get(name)
                if data:
                    with open(os.path.join(out, f"boot{n:02d}-{name}"), "wb") as f:
                        f.write(data)
        time.sleep(0.5)
    note("polling ended")


if __name__ == "__main__":
    main()
