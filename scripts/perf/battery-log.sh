#!/usr/bin/env bash
# Battery log on the unit, to compare stock 4.06 with this image (docs/plan-2026-10-20.md,
# step 4).
#
# The ZX507's fuel gauge (max1704x_battery) reports no current: capacity in whole percent,
# voltage, temperature. A comparison is the drop over hours at the same load, read from this
# log. The sampler (battery-sampler.sh) runs on the unit under nohup, so the cable can come
# out once it started, and reads only nodes the shell user can read, so stock needs no root.
# /sys/power/wakeup_count is not one of them: reading it blocks while a wakeup event is in
# progress.
#
# Usage: scripts/perf/battery-log.sh start <name> [interval-s] [adb-serial]
#        scripts/perf/battery-log.sh stop <name> [adb-serial]
#        scripts/perf/battery-log.sh pull <name> <out.csv> [adb-serial]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CMD="$1"
NAME="$2"
T=/data/local/tmp/battery-log/$NAME

case "$CMD" in
start)
	ADB=("$ROOT/tools/platform-tools/adb" -s "${4:-${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb serial of the unit}}")
	"${ADB[@]}" push "$ROOT/scripts/perf/battery-sampler.sh" /data/local/tmp/battery-sampler.sh >/dev/null
	"${ADB[@]}" shell "[ ! -e $T ] && mkdir -p $T" || { echo "$T exists on the unit" >&2; exit 1; }
	# Detached from every fd of the adb session, or adb shell waits for the sampler to end.
	"${ADB[@]}" shell "nohup sh /data/local/tmp/battery-sampler.sh $T ${3:-60} </dev/null >/dev/null 2>&1 &"
	;;
stop)
	ADB=("$ROOT/tools/platform-tools/adb" -s "${3:-${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb serial of the unit}}")
	"${ADB[@]}" shell "touch $T/stop"
	;;
pull)
	ADB=("$ROOT/tools/platform-tools/adb" -s "${4:-${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb serial of the unit}}")
	"${ADB[@]}" pull "$T/log.csv" "$3" >/dev/null
	echo "$3: $(($(wc -l <"$3") - 1)) samples"
	;;
*)
	echo "unknown command $CMD" >&2
	exit 1
	;;
esac
