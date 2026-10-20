#!/usr/bin/env bash
# Run bench-frames.sh on the unit detached from adb (a warm-up run, then the
# measured runs), so an adb server restart by another client does not cut a
# run short, and copy the measured output to <out-prefix>-<n>.txt, with
# /proc/loadavg every 5 s in <out-prefix>-load.txt. Sampling with `top` every
# 2 s cost the measured gestures frames on this unit.
#
# Usage: scripts/perf/bench-bg.sh <out-prefix> <scale per mille> [runs] [adb-serial]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$1"
SCALE="$2"
RUNS="${3:-1}"
ADB=("$ROOT/tools/platform-tools/adb" -s "${4:-${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb serial of the unit}}")
T=/data/local/tmp/bench-bg/$(date +%s)

"${ADB[@]}" shell "mkdir -p $T && cd $T && nohup sh -c '
	(while [ ! -e done ]; do cat /proc/loadavg; sleep 5; done >load.txt) &
	input keyevent KEYCODE_WAKEUP; input keyevent KEYCODE_HOME; sleep 2
	sh /data/local/tmp/bench-frames.sh $SCALE >/dev/null
	for i in \$(seq 1 $RUNS); do sh /data/local/tmp/bench-frames.sh $SCALE >run-\$i.txt; done
	touch done' >/dev/null 2>&1 &"
until "${ADB[@]}" shell "[ -e $T/done ]" 2>/dev/null; do
	"${ADB[@]}" wait-for-device
	sleep 10
done
for i in $(seq 1 "$RUNS"); do
	"${ADB[@]}" pull "$T/run-$i.txt" "$OUT-$i.txt" >/dev/null
done
"${ADB[@]}" pull "$T/load.txt" "$OUT-load.txt" >/dev/null
