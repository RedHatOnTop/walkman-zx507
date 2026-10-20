#!/usr/bin/env bash
# Decrypt a Sony Walkman .UPG firmware package into its inner Android OTA zip.
#
# Scheme reverse-engineered from Sony's own updater
# (com.sony.walkman.systemupdater, /system/priv-app/automagic/automagic.apk)
# and verified end to end against four packages on 2026-09-24:
#
#   header, 128 bytes:
#     [0:4]     "NWWM"
#     [4:60]    56 ASCII hex = SHA-224 of the decrypted payload
#     [60:96]   ASCII '0' fill
#     [96:108]  12 ASCII digits = decrypted payload size in bytes
#     [108:128] zero fill
#   payload: AES-256-CBC, no padding, starting at byte 128
#     key = bytes  0..31 of the 48-character NVP field `_KAS_`
#     iv  = bytes 32..47 of the same field
#   the decrypted stream is taken to the declared size and must hash to the
#   header's SHA-224; the trailing bytes of the ciphertext are discard padding
#   (observed 5, 9, 10 and 16 bytes) and must never be written into the zip.
#
# The key comes from the device itself, /vendor/usr/data/icx_nvp.cfg, the
# quoted field commented `#@ Key`:
#
#   adb shell cat /vendor/usr/data/icx_nvp.cfg > secrets/icx_nvp.cfg
#
# Behaviour note: the last ciphertext block does NOT carry valid PKCS#5 padding,
# so `openssl -d` must run with -nopad and the output must be truncated to the
# declared size. Decrypting with padding enabled and trusting the result is how
# earlier attempts went wrong.
#
# Usage:
#   scripts/decrypt-upg.sh <file.UPG> [-k|--key-file secrets/icx_nvp.cfg] [-o out.zip]
#   scripts/decrypt-upg.sh <file.UPG> --key <48-character string>
#   scripts/decrypt-upg.sh <file.UPG> --from-device        # read the cfg over adb
#
# Firmware is Sony proprietary: keep the outputs local and do not redistribute.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 <file.UPG> [-k <nvp cfg>] [-o out.zip]"
UPG="$1"; shift
KEYFILE="$ROOT/secrets/icx_nvp.cfg"
KEY=""
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -k|--key-file) KEYFILE="${2:-}"; shift 2 ;;
    --key)         KEY="${2:-}"; shift 2 ;;
    --from-device)
      command -v adb >/dev/null || die "adb not found"
      mkdir -p "$ROOT/secrets"
      adb shell cat /vendor/usr/data/icx_nvp.cfg >"$KEYFILE" || die "adb read failed"
      chmod 600 "$KEYFILE"
      shift ;;
    -o|--out)      OUT="${2:-}"; shift 2 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

[ -f "$UPG" ] || die "no such file: $UPG"

# --- key ---------------------------------------------------------------------
if [ -z "$KEY" ]; then
  [ -f "$KEYFILE" ] || die "key file not found: $KEYFILE (pass -k or --from-device)"
  KEY="$(env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 - "$KEYFILE" <<'PY'
import re, sys
blob = open(sys.argv[1], 'rb').read()
m = re.search(rb'^_KAS_=\s*(["\'])([^"\'\r\n]+)\1', blob, re.M)
if not m:
    sys.exit("could not find the quoted _KAS_ field in the NVP config")
key = m.group(2)
if len(key) != 48:
    sys.exit(f"_KAS_ is {len(key)} characters, expected 48")
sys.stdout.write(key.decode())
PY
)" || die "failed to extract the key from $KEYFILE"
fi
[ "${#KEY}" -eq 48 ] || die "key must be 48 characters, got ${#KEY}"

hex() { od -An -tx1 -v | tr -d ' \n'; }
KEY_HEX="$(printf '%s' "${KEY:0:32}" | hex)"
IV_HEX="$(printf '%s' "${KEY:32:16}" | hex)"

# --- header ------------------------------------------------------------------
MAGIC="$(dd if="$UPG" bs=1 count=4 2>/dev/null)"
[ "$MAGIC" = "NWWM" ] || die "$UPG does not start with the NWWM magic"
EXPECTED="$(dd if="$UPG" bs=1 skip=4 count=56 2>/dev/null | tr -d '\n')"
PLAIN_SIZE="$(dd if="$UPG" bs=1 skip=96 count=12 2>/dev/null | tr -d '\n')"
case "$PLAIN_SIZE" in ''|*[!0-9]*) die "unexpected plaintext-size field: '$PLAIN_SIZE'" ;; esac
PLAIN_SIZE=$((10#$PLAIN_SIZE))
FILE_SIZE="$(stat -c %s "$UPG")"
CIPHER_SIZE=$((FILE_SIZE - 128))
[ "$PLAIN_SIZE" -le "$CIPHER_SIZE" ] || die "declared size exceeds payload"

[ -n "$OUT" ] || OUT="${UPG%.UPG}.zip"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

echo "package : $(basename "$UPG")"
echo "cipher  : $CIPHER_SIZE bytes from offset 128"
echo "declared: $PLAIN_SIZE bytes of plaintext (discarding $((CIPHER_SIZE - PLAIN_SIZE)) trailing bytes)"

tail -c +129 "$UPG" |
  openssl enc -d -aes-256-cbc -nopad -K "$KEY_HEX" -iv "$IV_HEX" -out "$TMP" ||
  die "openssl failed"

# --- verify ------------------------------------------------------------------
GOT_SHA224="$(head -c "$PLAIN_SIZE" "$TMP" | sha224sum | awk '{print $1}')"
if [ "$GOT_SHA224" != "$EXPECTED" ]; then
  die "SHA-224 mismatch: header=$EXPECTED computed=$GOT_SHA224 (wrong key or wrong series?)"
fi
echo "SHA-224 : matches the header digest"

FINAL="$(mktemp "${OUT}.XXXXXX")"
head -c "$PLAIN_SIZE" "$TMP" >"$FINAL"
mv "$FINAL" "$OUT"
rm -f "$TMP"; trap - EXIT

if command -v unzip >/dev/null 2>&1; then
  if unzip -t "$OUT" >/dev/null 2>&1; then echo "ZIP     : integrity OK"; else echo "ZIP     : INTEGRITY FAILED" >&2; fi
fi
echo "output  : $OUT ($(stat -c %s "$OUT") bytes)"
echo "next    : unzip -o '$OUT' payload.bin payload_properties.txt -d extracted/"
