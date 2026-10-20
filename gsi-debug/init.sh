#!/zx/busybox sh
# Debug wrapper installed as /init of a GSI copy (scripts/debug-gsi.sh).
#
# The kernel mounts system_b as / (U-Boot appends skip_initramfs) and runs this
# as pid 1. It brings up a USB ECM gadget at 192.168.77.1 that serves the
# kernel log, logcat and process snapshots over HTTP, plus a command runner and
# a telnet shell, and then execs the GSI's real init. pstore does not survive a
# reboot on this unit, so this is the only way a failing boot can report itself.
#
# Sony's configfs has a single global android0 uevent device, so a second
# gadget breaks the kernel: when vendor early-boot makes g1 next to ours, the
# failed device_create leaves an error pointer that the next USB uevent
# dereferences. gsi-debug/zxdbg.rc therefore stops init at zygote-start, just
# before early-boot, until this script has removed its gadget. From then on
# the logs are mirrored to /data/zxlog/<n>/ and Android's own adb takes over.
#
# Host side: scripts/gsi-netlog.py.

B=/zx/busybox
R=/zx/run
W=$R/www

$B mount -t tmpfs -o mode=0755 tmpfs $R
$B mkdir -p $W/cgi-bin $R/bin
$B --install -s $R/bin
export PATH=$R/bin:/system/bin

# The kernel log first, so nothing is lost while the rest comes up. A reader
# that falls behind gets EPIPE; restarting it re-reads the ring from the start.
(
	while :; do
		$B cat /dev/kmsg >>$W/kmsg.log
		$B echo "### kmsg reader exited $?" >>$W/kmsg.log
		$B sleep 1
	done
) </dev/null >/dev/null 2>&1 &
KMSG=$!

# Kill a background loop together with the reader it is waiting on.
stop_tree() {
	$B kill -9 $1 $($B awk -v p=$1 '$4 == p { print $1 }' /proc/[0-9]*/stat 2>/dev/null)
}

$B mount -t proc proc /proc
$B cat /proc/sys/kernel/random/boot_id >$W/boot_id
$B mount -t sysfs sysfs /sys
$B mount -t configfs configfs /sys/kernel/config
$B mkdir -p /dev/pts
$B mount -t devpts devpts /dev/pts

$B echo "zxdbg: wrapper start, cmdline: $($B cat /proc/cmdline)" >/dev/kmsg

G=/sys/kernel/config/usb_gadget/zx
$B mkdir -p $G/strings/0x409 $G/configs/c.1/strings/0x409 $G/functions/ecm.usb0
$B echo 0x1d6b >$G/idVendor
$B echo 0x0104 >$G/idProduct
$B echo zxdbg >$G/strings/0x409/manufacturer
$B echo "ZX507 GSI debug" >$G/strings/0x409/product
$B echo zxdbg-$($B sed -n 's/.*androidboot.serialno=\([^ ]*\).*/\1/p' /proc/cmdline) >$G/strings/0x409/serialnumber
$B echo ecm >$G/configs/c.1/strings/0x409/configuration
$B echo 02:5a:58:35:30:01 >$G/functions/ecm.usb0/dev_addr
$B echo 02:5a:58:35:30:02 >$G/functions/ecm.usb0/host_addr
$B ln -s $G/functions/ecm.usb0 $G/configs/c.1/
udc=
for i in 1 2 3 4 5 6 7 8 9 10; do
	udc=$($B ls /sys/class/udc 2>/dev/null | $B head -n 1)
	[ -n "$udc" ] && break
	$B sleep 1
done
$B echo "$udc" >$G/UDC
$B echo "zxdbg: gadget on udc '$udc' rc=$?" >/dev/kmsg

ifname=$($B cat $G/functions/ecm.usb0/ifname 2>/dev/null)
$B ifconfig ${ifname:-usb0} 192.168.77.1 netmask 255.255.255.0 up
$B cat >$R/udhcpd.conf <<EOF
start 192.168.77.2
end 192.168.77.2
max_leases 1
interface ${ifname:-usb0}
lease_file $R/udhcpd.leases
opt subnet 255.255.255.0
opt lease 600
EOF
$B touch $R/udhcpd.leases
$B udhcpd -f $R/udhcpd.conf </dev/null >/dev/null 2>&1 &
UDHCPD=$!

# POST a shell script to /cgi-bin/sh and get its output back.
$B cat >$W/cgi-bin/sh <<'EOF'
#!/zx/busybox sh
export PATH=/zx/run/bin:/system/bin
echo "Content-Type: text/plain"
echo
f=/zx/run/cmd.$$
head -c "${CONTENT_LENGTH:-0}" >$f
sh $f 2>&1
echo "### exit $?"
rm -f $f
EOF
$B chmod 0755 $W/cgi-bin/sh
$B httpd -f -p 80 -h $W </dev/null >/dev/null 2>&1 &
HTTPD=$!
$B ln -s /zx/busybox $R/sh
$B telnetd -F -p 23 -l $R/sh </dev/null >/dev/null 2>&1 &
TELNETD=$!

$B echo "zxdbg: network up on ${ifname:-usb0}" >/dev/kmsg

# Hold the real init until the host has attached (scripts/gsi-telnetlog.py
# touches $R/go), so a boot that dies within seconds still reaches the host.
# Only while a USB host has configured the gadget, and for 20 s at most: the
# kernel's own firmware requests (SDMA at 0.5 s) wait for ueventd through the
# user helper, which gives up after 60 s. Without the SDMA firmware the UARTs
# have no DMA and the Bluetooth chip's firmware download fails.
i=0
while [ ! -e $R/go ] && [ $i -lt 20 ]; do
	[ $i -ge 3 ] && [ "$($B cat /sys/class/udc/*/state)" != configured ] && break
	$B sleep 1
	i=$((i + 1))
done
$B echo "zxdbg: host attach wait ${i}s" >/dev/kmsg

# init mounts its own /proc, /sys and /config; leave it a clean slate.
$B umount /sys/kernel/config
$B umount /sys
$B umount /proc

(
	$B sleep 3
	while :; do
		{
			$B echo "### uptime $($B cat /proc/uptime 2>/dev/null)"
			$B ps -o pid,ppid,stat,args 2>&1
		} >>$W/ps.log
		$B sleep 2
	done
) </dev/null >/dev/null 2>&1 &
PSLOG=$!

# logcat runs from the bootstrap runtime APEX once logd is up.
(
	while :; do
		if [ -S /dev/socket/logdr ]; then
			/system/bin/logcat -b all -v threadtime >>$W/logcat.log 2>>$W/logcat.err
			$B echo "### logcat exited $?" >>$W/logcat.log
		fi
		$B sleep 1
	done
) </dev/null >/dev/null 2>&1 &
LOGCAT=$!

(
	while [ ! -d /dev/zxdbg-handoff ]; do $B usleep 50000; done
	$B echo "zxdbg: handing USB over to Android" >/dev/kmsg
	C=/config/usb_gadget/zx
	$B echo "" >$C/UDC
	# Let the disconnect uevent work run before the gadget is freed.
	$B sleep 1
	$B rm $C/configs/c.1/ecm.usb0
	$B rmdir $C/configs/c.1/strings/0x409 $C/configs/c.1 $C/functions/ecm.usb0 $C/strings/0x409 $C
	$B echo "zxdbg: gadget removed rc=$?" >/dev/kmsg
	# The USB network went with the gadget. A listener left on it spins: httpd
	# kept a core at 100% for the whole session.
	$B kill $HTTPD $TELNETD $UDHCPD
	$B mkdir /dev/zxdbg-released
	n=0
	while [ -e /data/zxlog/$n ]; do n=$((n + 1)); done
	L=/data/zxlog/$n
	$B mkdir -p $L
	$B cp $W/boot_id $L/
	for o in $($B ls /data/zxlog); do
		[ "$o" -le $((n - 8)) ] 2>/dev/null && $B rm -rf /data/zxlog/$o
	done
	$B tail -n +1 -f $W/kmsg.log >>$L/kmsg.log &
	T1=$!
	$B tail -n +1 -f $W/logcat.log >>$L/logcat.log &
	T2=$!
	$B tail -n +1 -f $W/ps.log >>$L/ps.log &
	T3=$!
	# Mirror until 30 s after boot completes (zxdbg.rc makes /dev/zxdbg-booted);
	# adb has the logs from then on. Left running for the whole session, the
	# mirrors, the ps snapshots and this 1 Hz sync cost UI frames.
	while [ ! -d /dev/zxdbg-booted ]; do
		$B sync
		$B sleep 1
	done
	i=0
	while [ $i -lt 30 ]; do
		$B sync
		$B sleep 1
		i=$((i + 1))
	done
	for p in $KMSG $PSLOG $LOGCAT; do stop_tree $p; done
	$B sleep 1
	$B kill $T1 $T2 $T3
	$B sync
	$B rm -f $W/kmsg.log $W/logcat.log $W/ps.log
	$B echo "zxdbg: log mirror stopped after boot" >/dev/kmsg
) </dev/null >/dev/null 2>&1 &

$B echo "zxdbg: exec /system/bin/init" >/dev/kmsg
exec /system/bin/init "$@"
