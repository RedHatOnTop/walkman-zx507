#!/usr/bin/env python3
"""Stream the debug GSI's logs through its telnet shell (gsi-debug/init.sh).

On each connection it records ports and the wrapper's process list, releases
the wrapper's wait for the host, and then follows kmsg.log until the link
drops, one file per connection.

With `logcat` as the third argument it instead waits for the wrapper's
logcat.log and follows that.

Usage: gsi-telnetlog.py <out-dir> [seconds] [kmsg|logcat]
"""

import os
import socket
import sys
import time

DEV = "192.168.77.1"
IAC = 255


def strip_telnet(buf):
    out, i = bytearray(), 0
    while i < len(buf):
        b = buf[i]
        if b == IAC and i + 1 < len(buf):
            cmd = buf[i + 1]
            i += 3 if cmd in (251, 252, 253, 254) else 2
            continue
        out.append(b)
        i += 1
    return bytes(out)


def main():
    out = sys.argv[1]
    limit = float(sys.argv[2]) if len(sys.argv) > 2 else 1800
    mode = sys.argv[3] if len(sys.argv) > 3 else "kmsg"
    os.makedirs(out, exist_ok=True)
    events = open(os.path.join(out, f"events-{mode}.log"), "a", buffering=1)

    def note(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        events.write(line + "\n")
        print(line, flush=True)

    end = time.monotonic() + limit
    n = 0
    note("waiting for telnet on 23")
    while time.monotonic() < end:
        try:
            s = socket.create_connection((DEV, 23), timeout=0.5)
        except OSError:
            time.sleep(0.3)
            continue
        n += 1
        note(f"connection {n}")
        s.settimeout(300)
        if mode == "logcat":
            s.sendall(
                b"cat /proc/sys/kernel/random/boot_id; L=/zx/run/www/logcat.log;"
                b" while [ ! -s $L ]; do sleep 0.2; done; tail -n +1 -f $L\n"
            )
        else:
            s.sendall(
                b"cat /proc/sys/kernel/random/boot_id; netstat -ltn; ps -o pid,ppid,stat,args;"
                b" ls -la /zx/run /zx/run/www; touch /zx/run/go; tail -n +1 -f /zx/run/www/kmsg.log\n"
            )
        path = os.path.join(out, f"{mode}{n:02d}.log")
        size = 0
        with open(path, "wb") as f:
            while True:
                try:
                    data = s.recv(65536)
                except OSError as e:
                    note(f"connection {n} recv: {e}")
                    break
                if not data:
                    break
                data = strip_telnet(data)
                f.write(data)
                f.flush()
                size += len(data)
        s.close()
        note(f"connection {n} closed after {size} bytes")
    note("ended")


if __name__ == "__main__":
    main()
