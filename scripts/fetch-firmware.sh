#!/usr/bin/env bash
# Fetch official Sony Walkman NW-ZX500-series firmware (NWWM .UPG) from Sony's
# update CDN, verify each file, and record the results in a manifest.
#
# Usage:
#   scripts/fetch-firmware.sh            # fetch everything listed below
#   scripts/fetch-firmware.sh --list     # print targets, download nothing
#   scripts/fetch-firmware.sh --verify   # re-verify files already present
#
# Facts established while building this list (2026-09-24):
#   - The CDN serves the files directly: no cookies, no referer, HTTP 200.
#   - .UPG layout: bytes 0..3 are the ASCII magic "NWWM", bytes 4..59 are 56
#     ASCII hex characters (a SHA-224 sized digest), then padding to byte 128,
#     then the AES-CBC/PKCS5Padding payload wrapping a standard Android OTA zip.
#   - Sony's China service site (service.sony.com.cn) exposes the download URLs
#     through /casch/outDownload?method=findOne&path=<node>; the older records
#     still carry their downloadPath, which is how these URLs were found.
#   - Only these six NW-ZX500 files exist on the CDN as of 2026-09-24: two China
#     builds (4.04.00, 4.08.00, ~486 MB each) and four international 4.06.00
#     builds (~907-910 MB each, one per destination/series id).
#
# Firmware is Sony proprietary. Keep it local; do not redistribute.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-$ROOT/firmware}"
MANIFEST="${MANIFEST:-$DEST/MANIFEST.tsv}"
BASE="${BASE:-https://info.update.sony.net/PA001}"

# label|series|contents|filename
TARGETS=(
  "zx500_chn_4.04.00|NW-ZX500Series_0003|0013|NW-ZX500_0003_V4_04_00_NW_WM_FW.UPG"
  "zx500_chn_4.08.00|NW-ZX500Series_0003|0014|NW-ZX500_0003_V4_08_00_NW_WM_FW.UPG"
  "zx500_intl_4.06.00_s0|NW-ZX500Series_0000|0015|NW-ZX500_0000_V4_06_00_NW_WM_FW.UPG"
  "zx500_intl_4.06.00_s1|NW-ZX500Series_0001|0016|NW-ZX500_0001_V4_06_00_NW_WM_FW.UPG"
  "zx500_intl_4.06.00_s2|NW-ZX500Series_0002|0015|NW-ZX500_0002_V4_06_00_NW_WM_FW.UPG"
  "zx500_intl_4.06.00_s4|NW-ZX500Series_0004|0015|NW-ZX500_0004_V4_06_00_NW_WM_FW.UPG"
  "zx500_intl_4.06.00_s5|NW-ZX500Series_0005|0015|NW-ZX500_0005_V4_06_00_NW_WM_FW.UPG"
  # NW-A100 (A105) twin, same build number; probed 2026-10-14, series
  # 0000-0006 exist with 4.05.00/4.06.00 plus China 4.04.00/4.08.00 in 0003.
  "a100_intl_4.06.00_s0|NW-A100Series_0000|0015|NW-A100_0000_V4_06_00_NW_WM_FW.UPG"
)

MODE=fetch
case "${1:-}" in
  --list)   MODE=list ;;
  --verify) MODE=verify ;;
  "")       ;;
  *)        echo "usage: $0 [--list|--verify]" >&2; exit 2 ;;
esac

header() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    label url size_bytes last_modified sha256 embedded_hex payload_sha224 embedded_reproducible path fetched_utc
}

remote_size() {
  curl -fsSI --max-time 30 "$1" | tr -d '\r' |
    awk 'tolower($1) == "content-length:" { print $2 }'
}

remote_mtime() {
  curl -fsSI --max-time 30 "$1" | tr -d '\r' |
    awk 'tolower($1) == "last-modified:" { $1 = ""; sub(/^ /, ""); print }'
}

verify_one() {
  local label="$1" url="$2" path="$3" size="$4" mtime="$5"
  local magic embedded payload local_size sha256 reproducible
  magic="$(dd if="$path" bs=1 count=4 2>/dev/null)"
  [ "$magic" = "NWWM" ] || { echo "ERROR: $path lacks the NWWM magic" >&2; return 1; }
  embedded="$(dd if="$path" bs=1 skip=4 count=56 2>/dev/null | tr -d '\n')"
  payload="$(tail -c +129 "$path" | sha224sum | awk '{print $1}')"
  local_size="$(stat -c %s "$path")"
  sha256="$(sha256sum "$path" | awk '{print $1}')"
  # The embedded field is kept for change detection only. It does not reproduce
  # from any plaintext slice of the .UPG (tested: whole file, skip 4/60/128,
  # zeroed field, truncated tail, first MiB), so it is most likely the digest of
  # the decrypted payload. `no` here is expected, not a corruption signal.
  if [ "$embedded" = "$payload" ]; then reproducible=yes; else reproducible=no; fi
  if [ -n "$size" ] && [ "$local_size" != "$size" ]; then
    echo "ERROR: $path is $local_size bytes, CDN reports $size" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$url" "$local_size" "$mtime" "$sha256" "$embedded" "$payload" "$reproducible" \
    "${path#"$ROOT"/}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

mkdir -p "$DEST"

if [ "$MODE" = list ]; then
  for spec in "${TARGETS[@]}"; do
    IFS='|' read -r label series contents file <<<"$spec"
    printf '%s\n  %s/%s/contents/%s/%s\n' "$label" "$BASE" "$series" "$contents" "$file"
  done
  exit 0
fi

if [ "$MODE" = fetch ]; then
  # Rebuild from scratch: the manifest is derived data, and a partial rewrite
  # would otherwise leave duplicate rows for targets touched in two runs.
  tmp="$(mktemp "$MANIFEST.XXXXXX")"
  header >"$tmp"
  trap 'rm -f "$tmp"' EXIT
else
  tmp=""; header
fi

for spec in "${TARGETS[@]}"; do
  IFS='|' read -r label series contents file <<<"$spec"
  url="$BASE/$series/contents/$contents/$file"
  path="$DEST/$file"

  if [ "$MODE" = verify ] && [ ! -f "$path" ]; then
    echo "skip (absent): $label" >&2
    continue
  fi

  size="$(remote_size "$url")"
  mtime="$(remote_mtime "$url")"
  echo "== $label"
  echo "   $url"
  echo "   CDN size=$size  last-modified=$mtime"

  if [ "$MODE" = fetch ]; then
    if [ -f "$path" ] && [ "$(stat -c %s "$path")" = "$size" ]; then
      echo "   already complete, verifying"
    else
      echo "   downloading to $path"
      curl -fSL --retry 5 --retry-delay 5 --connect-timeout 30 -C - -o "$path" "$url"
    fi
    verify_one "$label" "$url" "$path" "$size" "$mtime" >>"$tmp"
  else
    verify_one "$label" "$url" "$path" "$size" "$mtime"
  fi
done

if [ "$MODE" = fetch ]; then
  mv "$tmp" "$MANIFEST"
  trap - EXIT
  echo
  echo "manifest: $MANIFEST"
  if command -v column >/dev/null 2>&1; then
    column -t -s "$(printf '\t')" "$MANIFEST"
  else
    cat "$MANIFEST"
  fi
  echo
  echo "note: embedded_reproducible=no is expected -- the 56-hex field at bytes"
  echo "      4..59 does not reproduce from any plaintext slice of the .UPG and is"
  echo "      most likely the digest of the decrypted payload. Integrity of what is"
  echo "      on disk is covered by size + sha256 in this manifest."
fi
