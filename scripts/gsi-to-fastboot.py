#!/usr/bin/env python3
"""Get a boot-looping debug GSI into U-Boot fastboot.

Waits for the /init wrapper's telnet shell (gsi-debug/init.sh), releases its
host-attach wait, then keeps asking init for `reboot,bootloader` through
sys.powerctl until the property
service takes it. That happens about 10 s into the boot, well before the GSI's
own reboot into recovery.

Usage: gsi-to-fastboot.py [seconds]
"""

import re
import socket
import sys
import time

DEV = "192.168.77.1"
CMD = (
    b"touch /zx/run/go; i=0; while [ $i -lt 120 ]; do"
    b" /system/bin/setprop sys.powerctl reboot,bootloader 2>/dev/null"
    b" && { echo POWERCTL_SET at $(cut -d' ' -f1 /proc/uptime); break; };"
    b" i=$((i + 1)); sleep 0.25; done\n"
)


def main():
    limit = float(sys.argv[1]) if len(sys.argv) > 1 else 900
    end = time.monotonic() + limit
    print(f"{time.strftime('%H:%M:%S')} waiting for telnet", flush=True)
    while time.monotonic() < end:
        try:
            s = socket.create_connection((DEV, 23), timeout=0.5)
        except OSError:
            time.sleep(0.3)
            continue
        print(f"{time.strftime('%H:%M:%S')} connected, sending", flush=True)
        s.settimeout(60)
        s.sendall(CMD)
        buf = b""
        try:
            while not re.search(rb"POWERCTL_SET at [0-9]", buf):
                data = s.recv(4096)
                if not data:
                    break
                buf += data
        except OSError as e:
            print(f"{time.strftime('%H:%M:%S')} recv: {e}", flush=True)
        # The telnet echo of CMD wraps at 80 columns, so match the real output only.
        line = re.findall(r"POWERCTL_SET at [0-9.]+", buf.decode(errors="replace"))
        print(f"{time.strftime('%H:%M:%S')} {line[-1] if line else 'no confirmation'}", flush=True)
        if line:
            return
    print(f"{time.strftime('%H:%M:%S')} gave up", flush=True)


if __name__ == "__main__":
    main()
