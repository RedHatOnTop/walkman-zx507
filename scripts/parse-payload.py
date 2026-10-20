#!/usr/bin/env python3
"""Parse the Chrome-OS/Android OTA payload header of a decrypted Sony .UPG zip.

Format (payload.bin):
    magic                   4 bytes  "CrAU"
    version                 u64 BE
    manifest_size           u64 BE
    metadata_signature_size u32 BE
    manifest                protobuf DeltaArchiveManifest
    metadata signature      bytes
    data blobs              ...

DeltaArchiveManifest:
    field 13: repeated PartitionUpdate partitions
PartitionUpdate:
    field  1: string partition_name
    field  6: PartitionInfo new_partition_info
    field  8: uint64   size            (older producers)
PartitionInfo:
    field  1: int64 size   <- full on-disk partition size in bytes
    field  2: bytes hash   <- SHA-256 of the raw partition image

Only the manifest is read; the multi-GB blob section is never touched.

Usage: parse_payload.py <decrypted.zip>
"""
import struct
import sys
import zipfile

WIRE_VARINT, WIRE_64, WIRE_LEN, WIRE_32 = 0, 1, 2, 5


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
    """Yield (field_number, wire_type, value) for a protobuf message."""
    i = 0
    n = len(buf)
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
            raise ValueError(f"unsupported wire type {wtype} for field {fnum}")
        yield fnum, wtype, val


def main(zip_path):
    with zipfile.ZipFile(zip_path) as z:
        with z.open("payload.bin") as f:
            head = f.read(4)
            if head != b"CrAU":
                sys.exit(f"not a payload: magic={head!r}")
            version = struct.unpack(">Q", f.read(8))[0]
            manifest_size = struct.unpack(">Q", f.read(8))[0]
            sig_size = struct.unpack(">I", f.read(4))[0]
            manifest = f.read(manifest_size)

    print(f"payload version   : {version}")
    print(f"manifest bytes    : {manifest_size}")
    print(f"metadata sig bytes: {sig_size}")
    print()

    rows = []
    total = 0
    for fnum, _w, val in fields(manifest):
        if fnum != 13:
            continue
        name, size, digest = None, None, None
        for pf, _pw, pv in fields(val):
            if pf == 1:
                name = pv.decode(errors="replace")
            elif pf in (6, 7):                 # PartitionInfo: 6 = old, 7 = new
                cand = {}
                for qf, _qw, qv in fields(pv):
                    if qf == 1 and isinstance(qv, int):
                        cand['size'] = qv
                    elif qf == 2 and isinstance(qv, bytes):
                        cand['hash'] = qv
                if cand.get('size'):
                    size = cand['size']
                if cand.get('hash'):
                    digest = cand['hash']
        rows.append((name, size, digest))
        if size:
            total += size

    rows.sort(key=lambda r: (r[1] or 0), reverse=True)
    print(f"{'partition':<14}{'size (bytes)':>16}{'MiB':>10}  sha256[:16]")
    for name, size, digest in rows:
        mib = f"{size / 1048576:.2f}" if size else "-"
        dh = digest.hex()[:16] if digest else "-"
        print(f"{name or '?':<14}{size if size else 0:>16}{mib:>10}  {dh}")
    print()
    print(f"{'TOTAL':<14}{total:>16}{total / 1048576:>10.2f}")
    print(f"partitions: {len(rows)}")


if __name__ == "__main__":
    main(sys.argv[1])