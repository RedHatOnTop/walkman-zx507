#!/usr/bin/env bash
# Watch a device through a boot attempt and grab logs the moment adb appears.
#
# Logs every USB/adb/fastboot state change with a timestamp. When adb comes up,
# it takes `adb root` (userdebug GSI), dumps dmesg, pstore and all log buffers,
# then keeps streaming `logcat -b all` until the device drops off.
#
# Usage: scripts/boot-watch.sh <serial> <out-dir> [seconds]

set -u
SERIAL="$1"
OUT="$2"
LIMIT="${3:-900}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/tools/platform-tools/adb -s $SERIAL"
FASTBOOT="$ROOT/tools/platform-tools/fastboot"
mkdir -p "$OUT"
LOG="$OUT/watch.log"

state() {
  local a f u
  a=$($ROOT/tools/platform-tools/adb devices 2>/dev/null | awk -v s="$SERIAL" '$1==s{print $2}')
  f=$($FASTBOOT devices 2>/dev/null | awk -v s="$SERIAL" '$1==s{print "fastboot"}')
  u=$(lsusb | grep -iE '054c:0d01|18d1:|0525:a4a5|1d6b:0104' | awk '{print $6}' | sort | tr '\n' ',')
  echo "adb=${a:-none} fastboot=${f:-none} usb=${u:-none}"
}

prev=""
grabbed=0
end=$((SECONDS + LIMIT))
while [ $SECONDS -lt $end ]; do
  s=$(state)
  if [ "$s" != "$prev" ]; then
    echo "$(date +%H:%M:%S) $s" | tee -a "$LOG"
    prev="$s"
  fi
  if [[ "$s" == adb=device* ]] && [ $grabbed -eq 0 ]; then
    grabbed=1
    t=$(date +%H%M%S)
    $ADB root >"$OUT/root-$t.txt" 2>&1
    sleep 2
    $ADB wait-for-device
    $ADB shell getprop >"$OUT/getprop-$t.txt" 2>&1
    $ADB shell dmesg >"$OUT/dmesg-$t.txt" 2>&1
    $ADB shell 'cat /sys/fs/pstore/* 2>/dev/null' >"$OUT/pstore-$t.txt" 2>&1
    $ADB logcat -b all -d >"$OUT/logcat-dump-$t.txt" 2>&1
    echo "$(date +%H:%M:%S) grabbed getprop/dmesg/pstore/logcat ($t)" | tee -a "$LOG"
    $ADB logcat -b all >"$OUT/logcat-stream-$t.txt" 2>&1 &
  fi
  sleep 2
done
echo "$(date +%H:%M:%S) watch ended" | tee -a "$LOG"
