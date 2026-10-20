#!/usr/bin/env bash
# services.jar and SystemUI compiled ahead of time on the host, into a GSI image copy
# (devlog 2026-10-20).
#
# izm-audio.sh, microg-gsi.sh and seamless-scale-gsi.sh change services.jar and lean-ui-gsi.sh
# changes SystemUI, so the image's own odex for them no longer match. Without a cached compile
# from the unit (services-odex.sh, systemui-odex.sh) both ran on the interpreter and JIT. This
# runs the image's own dex2oat64 under qemu-aarch64, in a sysroot made of the image's /system and
# every APEX payload, with the arguments those two scripts give it on the unit. argv[0] and the
# output paths are the unit's too: the odex stores its command line, so host paths would end up
# in the image, and a longer command line shifts the whole file. -j4 as on the unit, since the
# thread count changes the output. Checked against the unit's compiles of the same dex: the
# SystemUI odex and vdex and the services odex and art are identical, services.vdex lists two
# verifier strings in the other order.
#
# The APEXes' system server jars were compiled by the GSI build against services.jar: the class
# loader context in each of their odex lists it with its checksums, so the runtime rejects all 12
# once services.jar changes, and system_server runs them on the JIT. Each one that names
# services.jar is compiled again with the context its odex records. The GSI build stored no
# command line in them, and neither does this (--avoid-storing-invocation).
#
# Usage: scripts/odex-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="$ROOT/tools/qemu-dl/x/usr/bin/qemu-aarch64"
PART_BYTES=3145728000 # system_b
# The sysroot is ~700 MB; next to <out.img> rather than on tmpfs.
WORK="$(mktemp -d "$(dirname "$OUT")/.odex.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SR="$WORK/sysroot"
SVC=/system/framework/services.jar
SVC_OAT=/system/framework/oat/arm64/services
SVC_T=/data/local/tmp/services-odex
SYSUI=/system/system_ext/priv-app/SystemUI/SystemUI.apk
SYSUI_OAT=/system/system_ext/priv-app/SystemUI/oat/arm64/SystemUI
SYSUI_T=/data/local/tmp/systemui-odex
OAT=/system/framework/oat/arm64
SSJ_T=/data/local/tmp/sscp-odex

[ -x "$QEMU" ] || { echo "no $QEMU (scripts/fetch-tools.sh)" >&2; exit 1; }
cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"

mkdir -p "$SR/system/bin" "$SR/system/system_ext/priv-app" "$SR/apex" "$WORK/apex"
debugfs -R "rdump /system/framework /system/lib64 /system/etc $SR/system" "$OUT" >/dev/null 2>&1
debugfs -R "rdump $(dirname $SYSUI) $SR/system/system_ext/priv-app" "$OUT" >/dev/null 2>&1
for a in $(debugfs -R "ls /system/apex" "$OUT" 2>/dev/null | tr -s ' ' '\n' | awk '/\.c?apex$/'); do
	name="${a%.*}"
	debugfs -R "dump /system/apex/$a $WORK/apex/$a" "$OUT" 2>/dev/null
	if [ "${a##*.}" = capex ]; then
		unzip -q -p "$WORK/apex/$a" original_apex >"$WORK/apex/$name.apex"
		unzip -q -p "$WORK/apex/$name.apex" apex_payload.img >"$WORK/apex/$name.img"
	else
		unzip -q -p "$WORK/apex/$a" apex_payload.img >"$WORK/apex/$name.img"
	fi
	mkdir "$SR/apex/$name"
	debugfs -R "ls /" "$WORK/apex/$name.img" 2>/dev/null | tr -s ' ' '\n' |
		awk -v d="$SR/apex/$name" 'NF && $0 != "." && $0 != ".." && $0 != "lost+found" {print "rdump /" $0 " " d}' \
			>"$WORK/apex/$name.cmds"
	debugfs -f "$WORK/apex/$name.cmds" "$WORK/apex/$name.img" >/dev/null 2>&1
done
# /system/bin/linker64 is an absolute symlink, which qemu would resolve on the host.
cp "$SR/apex/com.android.runtime/bin/linker64" "$SR/system/bin/linker64"
for f in "$SR$SVC" "$SR$SYSUI" "$SR/apex/com.android.art/bin/dex2oat64"; do
	[ -s "$f" ] || { echo "$IN: no ${f#"$SR"}" >&2; exit 1; }
done

# A value from an odex's key-value store. It reads to the end: an early exit would leave tr
# with SIGPIPE, and pipefail would end the script.
oat_key() {
	tr '\0' '\n' <"$1" | awk -v k="$2" 'f && !d {print; d = 1} {f = !d && $0 == k}'
}
# The boot classpath the GSI's build compiled against, from one of its own odex.
BCP=$(oat_key "$SR/system/framework/oat/arm64/com.android.location.provider.odex" bootclasspath)
[ -n "$BCP" ] || { echo "$IN: no bootclasspath in com.android.location.provider.odex" >&2; exit 1; }

dex2oat() {
	"$QEMU" -L "$SR" -0 /apex/com.android.art/bin/dex2oat64 \
		-E LD_LIBRARY_PATH=/apex/com.android.art/lib64:/apex/com.android.runtime/lib64/bionic:/apex/com.android.runtime/lib64:/apex/com.android.i18n/lib64:/apex/com.android.os.statsd/lib64:/system/lib64 \
		-E ANDROID_ROOT=/system -E ANDROID_ART_ROOT=/apex/com.android.art \
		-E ANDROID_I18N_ROOT=/apex/com.android.i18n -E ANDROID_TZDATA_ROOT=/apex/com.android.tzdata \
		-E ANDROID_DATA=/data -E BOOTCLASSPATH="$BCP" \
		"$SR/apex/com.android.art/bin/dex2oat64" \
		--runtime-arg -Xms64m --runtime-arg -Xmx512m \
		--runtime-arg -Xbootclasspath:"$BCP" --runtime-arg -Xbootclasspath-locations:"$BCP" \
		--boot-image=/system/framework/boot.art:/system/framework/boot-framework.art \
		--android-root=/system "$@" \
		--instruction-set=arm64 --instruction-set-variant=cortex-a53 \
		--instruction-set-features=default --compiler-filter=speed \
		--compilation-reason=prebuilt "${EXTRA[@]}" --generate-mini-debug-info -j4 \
		2> >(grep -v 'linkerconfig/ld.config.txt' >&2)
}

# qemu maps a path into the sysroot only when it exists there, so the outputs are made first.
SSJ=()
for f in "$SR$OAT"/apex@*@classes.odex; do
	case "$(oat_key "$f" classpath)" in
	*"$SVC*"*) SSJ+=("$(basename "$f" .odex)") ;;
	esac
done
[ ${#SSJ[@]} -gt 0 ] || { echo "$IN: no APEX odex names $SVC in its context" >&2; exit 1; }
mkdir -p "$SR$SVC_T" "$SR$SYSUI_T" "$SR$SSJ_T"
for f in $SVC_T/services.{odex,vdex,art} $SYSUI_T/SystemUI.{odex,vdex}; do
	: >"$SR$f"
done
for n in "${SSJ[@]}"; do
	: >"$SR$SSJ_T/$n.odex"
	: >"$SR$SSJ_T/$n.vdex"
done
EXTRA=()
dex2oat --dex-file=$SVC --dex-location=$SVC \
	--oat-file=$SVC_T/services.odex --app-image-file=$SVC_T/services.art \
	--profile-file=$SVC.prof \
	--class-loader-context="PCL[/system/framework/com.android.location.provider.jar]"
EXTRA=(--resolve-startup-const-strings=true)
dex2oat --dex-file=$SYSUI --dex-location=$SYSUI --oat-file=$SYSUI_T/SystemUI.odex \
	--class-loader-context="PCL[]{}" --classpath-dir="$(dirname $SYSUI)"
EXTRA=(--avoid-storing-invocation)
for n in "${SSJ[@]}"; do
	# apex@com.android.art@javalib@service-art.jar@classes -> /apex/com.android.art/javalib/service-art.jar
	jar="/$(echo "${n%@classes}" | tr @ /)"
	# The recorded context without its checksums and the multidex entries they cover.
	clc=$(oat_key "$SR$OAT/$n.odex" classpath | sed -E 's/\*[0-9]+//g; s/:[^]:[]*![^]:[]*//g')
	dex2oat --dex-file="$jar" --dex-location="$jar" --oat-file="$SSJ_T/$n.odex" \
		--class-loader-context="$clc"
done
for f in $SVC_T/services.{odex,vdex,art} $SYSUI_T/SystemUI.{odex,vdex}; do
	[ -s "$SR$f" ] || { echo "dex2oat wrote no $f" >&2; exit 1; }
done
for n in "${SSJ[@]}"; do
	[ -s "$SR$SSJ_T/$n.odex" ] || { echo "dex2oat wrote no $SSJ_T/$n.odex" >&2; exit 1; }
done

exists() { debugfs -R "stat $1" "$OUT" 2>/dev/null | grep -q '^Inode:'; }
file() {
	exists "$2" && echo "rm $2"
	cat <<EOF
write $1 $2
sif $2 mode 0100644
sif $2 uid 0
sif $2 gid 0
ea_set -f $WORK/ctx-system $2 security.selinux
EOF
}
{
	for d in $(dirname $SVC_OAT) $(dirname $SYSUI_OAT); do
		exists "$d" || printf 'mkdir %s\nsif %s mode 040755\nea_set -f %s %s security.selinux\n' \
			"$d" "$d" "$WORK/ctx-system" "$d"
	done
	for x in odex vdex art; do
		file "$SR$SVC_T/services.$x" $SVC_OAT.$x
	done
	for x in odex vdex; do
		file "$SR$SYSUI_T/SystemUI.$x" $SYSUI_OAT.$x
	done
	for n in "${SSJ[@]}"; do
		for x in odex vdex; do
			file "$SR$SSJ_T/$n.$x" "$OAT/$n.$x"
		done
	done
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
echo "$OUT: services.jar, SystemUI and ${#SSJ[@]} APEX system server jars compiled on the host"
