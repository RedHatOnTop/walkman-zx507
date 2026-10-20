#!/usr/bin/env bash
# ab4.sh <label> <device setup shell>: setup, framework restart, warm-up run, measured run (framestats).
set -u
A="tools/platform-tools/adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb serial of the unit}"
D=${D:-device-capture/20261015T1348Z-gpu}
S="$(cd "$(dirname "$0")" && pwd)"
label=$1; setup=$2
$A shell "stop; sleep 2; $setup; start"
sleep 5
for i in $(seq 1 60); do [ "$($A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && [ -n "$($A shell pidof com.android.systemui 2>/dev/null)" ] && break; sleep 2; done
sleep 25
$A shell 'grep " /vendor/lib64/egl" /proc/mounts | cut -c1-80; getprop debug.sf.luma_sampling' 
$A shell 'sh /data/local/tmp/bench-frames.sh' > /dev/null
$A shell 'sh /data/local/tmp/bench-frames.sh' > $D/fs-$label.txt
python3 $S/fstats.py $D/fs-$label.txt
