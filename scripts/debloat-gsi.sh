#!/usr/bin/env bash
# Remove the GSI apps a Walkman has no use for, and optionally set the stock
# default wallpaper.
#
# The ZX507 has no modem, no camera and no printer. What goes is the user-facing
# side of those; the framework pieces (TeleService, Telecom, TelephonyProvider,
# MmsService, CarrierConfig, the contacts/calendar providers, PrintSpooler) stay
# because system_server and Settings bind to them on any device. NFC stays (the
# ZX507 pairs Bluetooth over NFC), and so do AOSP Music as a fallback player and
# Traceur for profiling. TrebleDroid ships ro.control_privapp_permissions=disable,
# so leftover allowlist entries for removed packages are inert.
#
# WALLPAPER=<png> installs that file as /system/media/default_wallpaper.png and
# points ro.config.wallpaper at it; the stock 4.06 framework-res uses a plain
# black 1440x1280 one.
#
# Usage: [WALLPAPER=<png>] scripts/debloat-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REMOVE="
/system/product/priv-app/Dialer
/system/product/app/messaging
/system/system_ext/app/WAPPushManager
/system/app/Stk
/system/app/SimAppDialog
/system/app/QcRilAm
/system/priv-app/CellBroadcastLegacyApp
/system/priv-app/CallLogBackup
/system/product/priv-app/ImsServiceEntitlement
/system/system_ext/priv-app/EmergencyInfo
/system/product/app/Camera2
/system/app/CameraExtensionsProxy
/system/product/priv-app/Contacts
/system/product/app/Calendar
/system/product/app/QuickSearchBox
/system/product/app/Gallery2
/system/app/BasicDreams
/system/product/app/PhotoTable
/system/app/EasterEgg
/system/priv-app/BuiltInPrintService
/system/app/PrintRecommendationService
"

cp --reflink=auto "$IN" "$OUT"

# debugfs has no recursive delete: files first, then directories bottom-up.
rm_tree() {
	local dir="$1" mode name
	while IFS=/ read -r _ _ mode _ _ name _; do
		case "$name" in "" | . | ..) continue ;; esac
		if [ "${mode:0:2}" = 04 ]; then
			rm_tree "$dir/$name"
		else
			echo "rm $dir/$name"
		fi
	done < <(debugfs -R "ls -p $dir" "$OUT" 2>/dev/null)
	echo "rmdir $dir"
}

: >"$WORK/cmds"
for d in $REMOVE; do
	debugfs -R "stat $d" "$OUT" 2>/dev/null | grep -q '^Inode:' || { echo "not in image: $d" >&2; exit 1; }
	rm_tree "$d" >>"$WORK/cmds"
done

if [ -n "${WALLPAPER:-}" ]; then
	printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"
	debugfs -R "dump /system/build.prop $WORK/build.prop" "$OUT" 2>/dev/null
	grep -q '^ro.config.wallpaper=' "$WORK/build.prop" && { echo "build.prop already sets ro.config.wallpaper" >&2; exit 1; }
	printf '\n# Stock ZX507 default wallpaper\nro.config.wallpaper=/system/media/default_wallpaper.png\n' >>"$WORK/build.prop"
	mode=$(debugfs -R "stat /system/build.prop" "$OUT" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p')
	cat >>"$WORK/cmds" <<EOF
rm /system/build.prop
write $WORK/build.prop /system/build.prop
sif /system/build.prop mode 0100$mode
sif /system/build.prop uid 0
sif /system/build.prop gid 0
ea_set -f $WORK/ctx-system /system/build.prop security.selinux
write $WALLPAPER /system/media/default_wallpaper.png
sif /system/media/default_wallpaper.png mode 0100644
sif /system/media/default_wallpaper.png uid 0
sif /system/media/default_wallpaper.png gid 0
ea_set -f $WORK/ctx-system /system/media/default_wallpaper.png security.selinux
EOF
fi

debugfs -w -f "$WORK/cmds" "$OUT" >"$WORK/debugfs.log" 2>&1
if grep -vE '^(debugfs [0-9.]+ \(|debugfs: |Allocated inode: [0-9]+$|$)' "$WORK/debugfs.log" | grep -q .; then
	cat "$WORK/debugfs.log" >&2
	exit 1
fi
e2fsck -fn "$OUT" >/dev/null
resize2fs -M "$OUT" >/dev/null
blocks=$(dumpe2fs -h "$OUT" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2); print $2}')
truncate -s $((blocks * 4096)) "$OUT"
e2fsck -fn "$OUT" >/dev/null
echo "$OUT: $((blocks * 4096)) bytes, removed $(grep -c '^rmdir' "$WORK/cmds") directories"
