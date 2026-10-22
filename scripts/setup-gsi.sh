#!/usr/bin/env bash
# The first boot asks before it starts, and the home screen starts tidy (user, 2026-10-22).
#
# - apps/setup (ZX507Setup, privileged, platform-signed) replaces AOSP's Provision, which marked
#   the unit set up without a page, so a fresh install came up in English on GMT. Its pages:
#   language, time zone, Wi-Fi, USB debugging, done. On a unit that is already set up (an update
#   over a running image) it steps aside at once.
# - The same package is Launcher3's partner customization: a fresh home screen has W.music and
#   Sound adjustment in the dock and nothing else. A home screen that exists is left alone.
#
# Usage: scripts/setup-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BT="$ROOT/tools/build-tools-dl/x/android-14"
PART_BYTES=3145728000 # system_b
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROVISION=/system/system_ext/priv-app/Provision
APP=/system/priv-app/ZX507Setup
PRIV_XML=/system/etc/permissions/privapp-permissions-zx507setup.xml

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

debugfs -R "stat $PROVISION" "$OUT" 2>/dev/null | grep -q '^Inode:' || { echo "$IN: no $PROVISION" >&2; exit 1; }
for f in $APP $PRIV_XML; do
	if debugfs -R "stat $f" "$OUT" 2>/dev/null | grep -q '^Inode:'; then
		echo "$IN: $f already exists" >&2
		exit 1
	fi
done

if [ -n "${KIT_FROM_SOURCE:-}" ]; then
	"$ROOT/apps/setup/build.sh" "$WORK/setup.apk" >/dev/null
else
	"$ROOT/scripts/prebuilt.sh" ZX507Setup.apk "$WORK/setup.apk"
fi

{
	echo '<?xml version="1.0" encoding="utf-8"?>'
	echo '<permissions>'
	echo "    <privapp-permissions package=\"$("$BT/aapt2" dump packagename "$WORK/setup.apk")\">"
	"$BT/aapt2" dump permissions "$WORK/setup.apk" |
		sed -n "s/^uses-permission: name='\([^']*\)'.*/        <permission name=\"\1\"\/>/p" |
		sort -u
	echo '    </privapp-permissions>'
	echo '</permissions>'
} >"$WORK/privapp.xml"

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

file() {
	cat <<EOF
write $1 $2
sif $2 mode 0100644
sif $2 uid 0
sif $2 gid 0
ea_set -f $WORK/ctx-system $2 security.selinux
EOF
}
{
	rm_tree $PROVISION
	cat <<EOF
mkdir $APP
sif $APP mode 040755
ea_set -f $WORK/ctx-system $APP security.selinux
EOF
	file "$WORK/setup.apk" $APP/ZX507Setup.apk
	file "$WORK/privapp.xml" $PRIV_XML
} >"$WORK/cmds"

truncate -s "$PART_BYTES" "$OUT"
resize2fs "$OUT" >/dev/null
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
echo "$OUT: first-run setup in place of Provision, launcher home layout"
