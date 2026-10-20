#!/usr/bin/env python3
"""List or extract partitions from a decrypted Sony .UPG / Android OTA payload.

Replaces the missing `payload-dumper-go` for the parts this project needs, using
only the standard library. Reads `payload.bin` from inside the decrypted zip.

Supported install-operation types:
    REPLACE (0)      raw, copied from the data blob section
    REPLACE_BZ (1)   bzip2
    REPLACE_XZ (8)   xz/lzma
    ZERO (6)         zero fill (dst_extents define the span)
Anything else (MOVE, BSDIFF, SOURCE_*, PUFFDIFF, BROTLI_BSDIFF) is a delta
operation and is reported as unsupported -- full OTAs do not use them.

Usage:
    extract-partition.py <decrypted.zip> --list
    extract-partition.py <decrypted.zip> --extract <partition> -o out.img
    extract-partition.py <decrypted.zip> --extract <partition> --info
"""
import argparse
import bz2
import lzma
import struct
import sys
import zipfile

BLOCK = 4096
WIRE_VARINT, WIRE_64, WIRE_LEN, WIRE_32 = 0, 1, 2, 5
OP_NAMES = {
    0: "REPLACE", 1: "REPLACE_BZ", 2: "MOVE", 3: "BSDIFF",
    4: "SOURCE_COPY", 5: "SOURCE_BSDIFF", 6: "ZERO", 7: "DISCARD",
    8: "REPLACE_XZ", 9: "PUFFDIFF", 10: "BROTLI_BSDIFF",
}
SUPPORTED = {0, 1, 6, 8}


def read_varint(buf, i):
    shift = 0
    val = 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            return val, i
        shift += 7


def fields(buf):
    i, n = 0, len(buf)
    while i < n:
        key, i = read_varint(buf, i)
        fnum, wtype = key >> 3, key & 7
        if wtype == WIRE_VARINT:
            val, i = read_varint(buf, i)
        elif wtype == WIRE_64:
            val = buf[i:i + 8]; i += 8
        elif wtype == WIRE_LEN:
            ln, i = read_varint(buf, i)
            val = buf[i:i + ln]; i += ln
        elif wtype == WIRE_32:
            val = buf[i:i + 4]; i += 4
        else:
            raise ValueError(f"wire type {wtype}")
        yield fnum, wtype, val


def parse_header(zip_path):
    with zipfile.ZipFile(zip_path) as z:
        with z.open("payload.bin") as f:
            if f.read(4) != b"CrAU":
                sys.exit("not an OTA payload")
            version = struct.unpack(">Q", f.read(8))[0]
            manifest_size = struct.unpack(">Q", f.read(8))[0]
            sig_size = struct.unpack(">I", f.read(4))[0]
            manifest = f.read(manifest_size)
    blob_base = 24 + manifest_size + sig_size
    return version, manifest, blob_base, zip_path


def parse_partitions(manifest):
    """Return {name: {'size': int, 'hash': bytes, 'ops': [...]}}."""
    parts = {}
    for fnum, _w, val in fields(manifest):
        if fnum != 13:
            continue
        name, size, phash, ops = None, 0, None, []
        for pf, _pw, pv in fields(val):
            if pf == 1:
                name = pv.decode(errors="replace")
            elif pf in (6, 7):                      # old, new PartitionInfo
                info = {}
                for qf, _qw, qv in fields(pv):
                    if qf == 1 and isinstance(qv, int):
                        info["size"] = qv
                    elif qf == 2 and isinstance(qv, bytes):
                        info["hash"] = qv
                if info.get("size"):
                    size = info["size"]
                if info.get("hash"):
                    phash = info["hash"]
            elif pf == 8:                           # InstallOperation
                op = {"type": 0, "data_offset": 0, "data_length": 0, "dst": []}
                for qf, _qw, qv in fields(pv):
                    if qf == 1 and isinstance(qv, int):
                        op["type"] = qv
                    elif qf == 2 and isinstance(qv, int):
                        op["data_offset"] = qv
                    elif qf == 3 and isinstance(qv, int):
                        op["data_length"] = qv
                    elif qf == 6:                   # dst_extents
                        ext = {}
                        for ef, _ew, ev in fields(qv):
                            if ef == 1 and isinstance(ev, int):
                                ext["start"] = ev
                            elif ef == 2 and isinstance(ev, int):
                                ext["num"] = ev
                        if "start" in ext:
                            op["dst"].append((ext.get("start", 0), ext.get("num", 0)))
                ops.append(op)
        parts[name] = {"size": size, "hash": phash, "ops": ops}
    return parts


def summarize(name, info):
    total_data = sum(o["data_length"] for o in info["ops"])
    kinds = {}
    for o in info["ops"]:
        kinds[OP_NAMES.get(o["type"], str(o["type"]))] = kinds.get(
            OP_NAMES.get(o["type"], str(o["type"])), 0) + 1
    return total_data, kinds


def extract(zip_path, name, out_path, info_only=False):
    version, manifest, blob_base, _ = parse_header(zip_path)
    parts = parse_partitions(manifest)
    if name not in parts:
        sys.exit(f"no such partition: {name} (have: {', '.join(sorted(parts))})")
    info = parts[name]
    total_data, kinds = summarize(name, info)
    print(f"partition   : {name}")
    print(f"size        : {info['size']:,} bytes")
    print(f"sha256      : {info['hash'].hex() if info['hash'] else '-'}")
    print(f"operations  : {len(info['ops'])} ({kinds})")
    print(f"blob bytes  : {total_data:,} (compressed where applicable)")
    unsupported = [o for o in info["ops"] if o["type"] not in SUPPORTED]
    if unsupported:
        sys.exit(f"unsupported op types present: "
                 f"{sorted({OP_NAMES.get(o['type']) for o in unsupported})}")
    if info_only:
        return

    with zipfile.ZipFile(zip_path) as z, z.open("payload.bin") as f, open(out_path, "wb") as out:
        for o in info["ops"]:
            if o["type"] == 6:
                nbytes = sum(nb * BLOCK for _s, nb in o["dst"])
                data = b"\x00" * nbytes
            else:
                f.seek(blob_base + o["data_offset"])
                raw = f.read(o["data_length"])
                if o["type"] == 0:
                    data = raw
                elif o["type"] == 1:
                    data = bz2.decompress(raw)
                else:
                    data = lzma.decompress(raw)
            pos = 0
            for start_blk, num_blk in o["dst"]:
                span = num_blk * BLOCK
                out.seek(start_blk * BLOCK)
                out.write(data[pos:pos + span])
                pos += span
        out.truncate(info["size"])
    print(f"wrote       : {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("zip")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--extract")
    ap.add_argument("--info", action="store_true")
    ap.add_argument("-o", "--out")
    a = ap.parse_args()

    if a.list:
        version, manifest, blob_base, _ = parse_header(a.zip)
        parts = parse_partitions(manifest)
        print(f"payload version {version}; data blob starts at {blob_base:,}")
        print(f"{'partition':<14}{'size':>16}{'blob':>16}  ops")
        tot = 0
        for n, i in sorted(parts.items(), key=lambda kv: -kv[1]["size"]):
            tb, kinds = summarize(n, i)
            tot += i["size"]
            print(f"{n:<14}{i['size']:>16,}{tb:>16,}  {len(i['ops'])}")
        print(f"{'TOTAL':<14}{tot:>16,}")
        return
    if a.extract:
        if not a.info and not a.out:
            sys.exit("--extract needs -o <out.img> (or use --info)")
        extract(a.zip, a.extract, a.out, info_only=a.info)
        return
    ap.print_help()


if __name__ == "__main__":
    main()