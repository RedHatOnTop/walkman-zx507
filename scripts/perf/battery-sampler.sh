#!/system/bin/sh
# Runs on the unit (scripts/perf/battery-log.sh pushes and starts it): one CSV line every
# <interval> s into <dir>/log.csv until <dir>/stop exists. Each line carries the wall time,
# because sleep does not advance while the unit is suspended.
#
# Usage: battery-sampler.sh <dir> <interval-s>

D="$1"
I="$2"
B=/sys/class/power_supply/max1704x_battery

echo epoch,uptime_s,capacity,voltage_uv,temp_dc,status,wakefulness >"$D/log.csv"
while [ ! -e "$D/stop" ]; do
	# The backlight node is not readable as shell; PowerManager's state is.
	w=$(dumpsys power 2>/dev/null | grep -m1 -o 'mWakefulness=[A-Za-z]*')
	echo "$(date +%s),$(cut -d' ' -f1 /proc/uptime),$(cat $B/capacity),$(cat $B/voltage_now),$(cat $B/temp),$(cat $B/status),${w#*=}" >>"$D/log.csv"
	sleep "$I"
done
