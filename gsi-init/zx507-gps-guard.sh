#!/system/bin/sh
# Unstick Sony's gps_fw_update.sh when the CXD5603 never answers it.
#
# The vendor script asks the GPS chip for its firmware version over
# /dev/ttymxc2 and holds gps_ctl busy=1 until it is done. If the chip never
# answers, the GNSS HAL keeps exiting on busy, system_server blocks in
# GnssNative.isSupported() waiting for the HAL, and its watchdog restarts it
# every ~100 s (devlog 2026-10-15, the 19:43 boot). After 30 s this stops a
# version query that is still hanging and clears busy. A firmware write
# (gps_write_fw -f) is never touched.

sleep 30
[ "$(getprop init.svc.gps_fw_update)" = running ] || exit 0
script=$(getprop init.svc_debug_pid.gps_fw_update)
[ -n "$script" ] || exit 0

children=$(pgrep -P "$script")
stuck=
for c in $children; do
	cmd=$(tr '\0' ' ' </proc/"$c"/cmdline 2>/dev/null)
	case "$cmd" in
	*gps_write_fw*" -v"*) stuck=1 ;;
	*gps_write_fw*" -f"*) exit 0 ;;
	esac
done
[ -n "$stuck" ] || exit 0

kill -9 "$script" $children
echo 0 >/sys/module/gps_ctl/parameters/busy
log -p w -t zx507-gps-guard "CXD5603 version query hung for 30 s; stopped gps_fw_update.sh, busy=0"
