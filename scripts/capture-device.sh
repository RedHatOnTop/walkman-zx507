#!/usr/bin/env bash
# Read-only device capture for the NW-ZX507, to be run BEFORE any unlock,
# root, or flash. Nothing here modifies the player: no `adb root`, no
# `adb remount`, no fastboot, no writes of any kind.
#
# Usage:
#   scripts/capture-device.sh              # everything except the (slow) bugreport
#   scripts/capture-device.sh --bugreport  # also run `adb bugreport`
#   scripts/capture-device.sh --serial <serial>   # pick one of several devices
#
# Output:
#   device-capture/<UTC-timestamp>/   plain text captures
#   secrets/icx_nvp.cfg               firmware decryption key (mode 0600)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ROOT/device-capture/$STAMP"
SECRETS="$ROOT/secrets"
BUGREPORT=0
SERIAL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bugreport) BUGREPORT=1; shift ;;
    --serial)    SERIAL="${2:-}"; shift 2 ;;
    *) echo "usage: $0 [--bugreport] [--serial <serial>]" >&2; exit 2 ;;
  esac
done

# Prefer the locally installed platform-tools so the capture does not depend on
# a system package being present.
if [ -x "$ROOT/tools/platform-tools/adb" ]; then
  ADB="$ROOT/tools/platform-tools/adb"
elif command -v adb >/dev/null 2>&1; then
  ADB="$(command -v adb)"
else
  echo "error: adb not found (tools/platform-tools/adb or PATH)" >&2
  exit 1
fi

adb() {
  if [ -n "$SERIAL" ]; then "$ADB" -s "$SERIAL" "$@"; else "$ADB" "$@"; fi
}

echo "adb: $ADB ($("$ADB" version | head -1))"

STATE="$(adb get-state 2>&1 | tr -d '\r' || true)"
if [ "$STATE" != "device" ]; then
  echo "error: device state is '$STATE', expected 'device'" >&2
  echo "       check the USB cable, USB debugging, and the on-device authorisation prompt" >&2
  "$ADB" devices -l || true
  exit 1
fi

mkdir -p "$OUT" "$SECRETS"
chmod 700 "$SECRETS"

# Capture a command to a file without aborting the run when it fails (many of
# these do not exist on every build, and a partial capture beats no capture).
cap() {
  local name="$1"; shift
  printf '$ %s\n' "$*" >"$OUT/$name.txt"
  if "$@" >>"$OUT/$name.txt" 2>&1; then
    printf '\n[exit 0]\n' >>"$OUT/$name.txt"
  else
    printf '\n[nonzero exit -- command unavailable or denied]\n' >>"$OUT/$name.txt"
  fi
  printf '  %-28s %s\n' "$name" "$(wc -c <"$OUT/$name.txt") bytes"
}

capdev() {
  local name="$1"; shift
  cap "$name" adb shell "$@"
}

# Multi-command captures must go through adb as ONE string. Passing
# `sh -c 'cmd'` as separate argv entries does not survive adb's argument
# concatenation: the device shell re-parses it and the command silently does
# something else (that bug made the first capture list / instead of /vendor).
capsh() {
  local name="$1"; shift
  cap "$name" adb shell "$1"
}

echo "capturing to $OUT"

SERIALNO="$(adb get-serialno 2>/dev/null | tr -d '\r' || echo unknown)"
{
  echo "captured_utc: $STAMP"
  echo "serial: $SERIALNO"
  echo "adb: $("$ADB" version | head -1)"
  echo "state: $STATE"
} >"$OUT/_meta.txt"
cat "$OUT/_meta.txt"

capdev getprop getprop
capsh  getprop_sorted 'getprop | sort'
capdev partitions cat /proc/partitions
capdev by_name ls -l /dev/block/by-name
capsh  block_sizes 'for d in /dev/block/by-name/*; do n=$(basename "$d"); t=$(readlink -f "$d" | sed "s|/dev/block/||"); s=$(cat /sys/class/block/$t/size 2>/dev/null); [ -n "$s" ] && echo "$n $t $((s*512))"; done'
capsh  sysfs_part_sizes 'for f in /sys/class/block/mmcblk2p*/size; do b=$(basename $(dirname $f)); echo "$b $(cat $f) sectors"; done'
capdev mounts cat /proc/mounts
capsh fstab 'cat /vendor/etc/fstab* /fstab* 2>/dev/null'
capdev cmdline cat /proc/cmdline
capdev version cat /proc/version
capdev meminfo cat /proc/meminfo
capdev cpuinfo cat /proc/cpuinfo
capdev vintf_manifest cat /vendor/etc/vintf/manifest.xml
capdev vintf_list ls -l /vendor/etc/vintf
capdev hal_libs ls -l /vendor/lib64/hw
capdev hal_libs32 ls -l /vendor/lib/hw
capsh audio_hal_details 'ls -l /vendor/lib64/hw/*audio* 2>/dev/null; echo ---; ls -l /vendor/lib64/hw/*bluetooth* 2>/dev/null'
capdev vendor_build cat /vendor/build.prop
capdev system_build cat /system/build.prop
capdev default_prop cat /default.prop
capsh packages 'pm list packages -f'
capsh packages_thirdparty 'pm list packages -3'
capsh pm_features 'pm list features'
capsh gms_check 'pm list packages | grep -c google'
capdev dmesg dmesg
capsh df 'df -h'
capsh lshal 'lshal 2>/dev/null | head -400'
capdev getenforce getenforce
capsh props_selinux 'getprop | grep -E "selinux|verity|dm-"'
capsh audio_cards 'cat /proc/asound/cards 2>/dev/null; echo ---; ls /proc/asound 2>/dev/null'
capsh codec_nodes 'ls -l /proc/icx* 2>/dev/null; echo ---; ls /sys/class/block 2>/dev/null'

# The firmware decryption key. Never print it; report only its shape.
NVP_REPORT="$OUT/icx_nvp.report.txt"
NVP_STDERR="$OUT/icx_nvp.stderr.txt"
if adb shell cat /vendor/usr/data/icx_nvp.cfg >"$SECRETS/icx_nvp.cfg" 2>"$NVP_STDERR"; then
  chmod 600 "$SECRETS/icx_nvp.cfg"
  SIZE="$(wc -c <"$SECRETS/icx_nvp.cfg")"
  KEY="$(tr -d '\r\n' <"$SECRETS/icx_nvp.cfg" | grep -o -E '[A-Za-z0-9]{48}' | head -1 || true)"
  { echo "path: /vendor/usr/data/icx_nvp.cfg"
    echo "captured: yes"
    echo "size_bytes: $SIZE"
    echo "48_char_key_present: $([ "${#KEY}" -eq 48 ] && echo yes || echo no)"
    echo "store: secrets/icx_nvp.cfg (mode 0600), contents deliberately not printed"
  } >"$NVP_REPORT"
  if [ "${#KEY}" -eq 48 ]; then
    echo "  NVP config                captured, 48-char key found -> secrets/icx_nvp.cfg (0600)"
  else
    echo "  NVP config                captured ($SIZE bytes) but no 48-char key run found" >&2
  fi
else
  { echo "path: /vendor/usr/data/icx_nvp.cfg"
    echo "captured: no"
    echo "stderr:"; sed 's/^/  /' "$NVP_STDERR"
  } >"$NVP_REPORT"
  echo "  NVP config                NOT captured (see $NVP_REPORT)" >&2
fi

if [ "$BUGREPORT" = 1 ]; then
  echo "running adb bugreport (this can take a few minutes)"
  ( cd "$OUT" && adb bugreport bugreport.zip ) || echo "  bugreport failed (non-fatal)"
fi

echo
echo "capture directory: $OUT"
ls -l "$OUT" | sed 's/^/  /'
echo
echo "next: scripts/decrypt-upg.sh firmware/<file>.UPG --key-file secrets/icx_nvp.cfg -o extracted/<file>.zip"
