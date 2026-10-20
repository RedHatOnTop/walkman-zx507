#!/usr/bin/env bash
# ZX507 compatibility fixes on a GSI image copy. Each one answers a failure the
# unit showed on a boot (devlog 2026-10-14):
#
# - task_profiles.json gains a CgroupEventControl attribute. This lmkd looks the
#   memcg event-control file up under that name while the json only has
#   MemCgroupEventControl; Sony's 4.14 has no PSI, so lmkd is left without a
#   pressure source, exits every 5 s, and being critical takes init down
#   before boot completes.
# - debug.renderengine.backend=threaded: SurfaceFlinger's Skia RenderEngine
#   aborts in primeShaderCache ("Unable to generate SkImage") on the Vivante
#   GLES driver. Android 13 still has the GLES engine.
# - persist.sys.sf.color_saturation=1.0: with the property unset,
#   ColorDisplayService picks the Boosted color mode and writes 1.1. The i.MX
#   HWC cannot apply that color matrix, so every frame goes through GPU client
#   composition, and on this Vivante driver that shows older screens through
#   whenever anything moves. 1.0 is read as Natural and keeps composition on
#   the HWC.
# - ZX507NoRoundWindows (gsi-overlays/noroundwin, built by build-overlay.sh
#   against the image's own framework-res): config_supportsRoundedCornersOnWindows
#   false. Launcher3's icon launch otherwise puts a corner radius on the window
#   leash, which sends those frames to the same GPU composition path.
# - surfaceflinger: android::Layer::hasRoundedCorners() returns false. Any
#   layer with a corner radius is forced to client composition, and Launcher3
#   still rounds the leash when closing into an icon and launching from
#   recents. With the patch those frames stay on the HWC with square corners.
#   Only the ci-20230905 binary is patched (sha256 checked); the function's
#   offset comes from its .gnu_debugdata symbols.
# - persist.sys.overlay.devinputjack=true enables TrebleDroid's own overlay
#   for config_useDevInputEventForAudioJack. The ZX507 reports the headphone
#   jack only as SW_HEADPHONE_INSERT on "imx-audio-cxd3778gf Headphone"; the
#   extcon HEADPHONE cable belongs to another chip and stays 0. Without it the
#   policy never sees Wired Headphones, the unit's only output.
# - gsi-init/zx507-audio.rc, gated on persist.sys.zx507.highres_mixer=true:
#   binds the vendor's audio_policy_configuration_highres.xml over the
#   default one, so the mixer runs at 44.1-192 kHz like stock did.
# - gsi-init/zx507-gps.rc + zx507-gps-guard.sh: if Sony's gps_fw_update.sh
#   still waits for the GPS chip's version answer after 30 s, stop it and
#   clear gps_ctl busy. Otherwise system_server waits on the GNSS HAL and
#   its watchdog restarts it every ~100 s.
# - persist.sys.bt.max_vendor_cap=0, TrebleDroid's switch that leaves the
#   controller's vendor capabilities unread. The QCA ROME firmware rejects
#   APCF read-extended-features (0xfd57 0xff), which Android 13 sends when
#   its scanner starts, with a Command Complete for opcode 0x0157; the HCI
#   layer aborts on the mismatch, so Bluetooth crashed at every start.
# - SurfaceFlinger's vsync budgets as durations: 33.3 ms for the app (UI
#   thread, RenderThread and the GC600's GPU time), 12 ms for SurfaceFlinger
#   (the HWC's G2D present takes 7 ms on average). With the default split a
#   heavy frame misses its deadline; A/B on the unit (devlog 2026-10-15):
#   QS shade 28.8 % -> 12.8 % janky, launcher 9.7 % -> 4.6 %, Settings
#   0.16 % -> 0 %, for about 12 ms more touch-to-display latency.
#
# Usage: scripts/compat-gsi.sh <in.img> <out.img>

set -euo pipefail
IN="$1"
OUT="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROPS="
debug.renderengine.backend=threaded
persist.sys.sf.color_saturation=1.0
persist.sys.overlay.devinputjack=true
persist.sys.zx507.highres_mixer=true
persist.sys.bt.max_vendor_cap=0
debug.sf.use_phase_offsets_as_durations=1
debug.sf.late.app.duration=33300000
debug.sf.early.app.duration=33300000
debug.sf.earlyGl.app.duration=33300000
debug.sf.late.sf.duration=12000000
debug.sf.early.sf.duration=12000000
debug.sf.earlyGl.sf.duration=12000000
"
TP=/system/etc/task_profiles.json
OVL=/system/product/overlay/ZX507NoRoundWindows
RC=/system/etc/init/zx507-audio.rc
GPS_RC=/system/etc/init/zx507-gps.rc
GPS_GUARD=/system/bin/zx507-gps-guard.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SF=/system/bin/surfaceflinger
SF_SHA256=057f363305e79eac0ac0b9693de51bceddf8b0381bc56972ee6ef28fb012851d
SF_HAS_ROUNDED_CORNERS=0x10993c

cp --reflink=auto "$IN" "$OUT"
printf '%s\0' u:object_r:system_file:s0 >"$WORK/ctx-system"
printf '%s\0' u:object_r:surfaceflinger_exec:s0 >"$WORK/ctx-sf"
printf '%s\0' u:object_r:phhsu_exec:s0 >"$WORK/ctx-phhsu"

debugfs -R "dump $SF $WORK/surfaceflinger" "$OUT" 2>/dev/null
echo "$SF_SHA256  $WORK/surfaceflinger" | sha256sum -c --quiet -
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I - "$WORK/surfaceflinger" "$SF_HAS_ROUNDED_CORNERS" <<'PYEOF'
import sys
path, off = sys.argv[1], int(sys.argv[2], 0)
b = bytearray(open(path, "rb").read())
# sub sp, sp, #0x40; stp x29, x30, [sp, #0x20]  ->  mov w0, wzr; ret
assert b[off:off + 8] == bytes.fromhex("ff0301d1fd7b02a9"), b[off:off + 8].hex()
b[off:off + 8] = bytes.fromhex("e0031f2ac0035fd6")
open(path, "wb").write(b)
PYEOF

debugfs -R "dump /system/framework/framework-res.apk $WORK/framework-res.apk" "$OUT" 2>/dev/null
"$(dirname "$0")/build-overlay.sh" noroundwin "$WORK/framework-res.apk" "$WORK/overlay.apk"

debugfs -R "dump $TP $WORK/task_profiles.json" "$OUT" 2>/dev/null
env -u PYTHONHOME -u PYTHONPATH /usr/bin/python3 -I - "$WORK/task_profiles.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
names = {a["Name"] for a in d["Attributes"]}
src = next(a for a in d["Attributes"] if a["Name"] == "MemCgroupEventControl")
if "CgroupEventControl" not in names:
    d["Attributes"].append(dict(src, Name="CgroupEventControl"))
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
PYEOF

debugfs -R "dump /system/build.prop $WORK/build.prop" "$OUT" 2>/dev/null
printf '\n# ZX507 compatibility (scripts/compat-gsi.sh)\n' >>"$WORK/build.prop"
for p in $PROPS; do
	grep -q "^${p%%=*}=" "$WORK/build.prop" && { echo "build.prop already sets ${p%%=*}" >&2; exit 1; }
	echo "$p" >>"$WORK/build.prop"
done

replace() {
	local src="$1" dst="$2" mode
	mode=$(debugfs -R "stat $dst" "$OUT" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p')
	cat <<EOF
rm $dst
write $src $dst
sif $dst mode 0100$mode
sif $dst uid 0
sif $dst gid 0
ea_set -f $WORK/ctx-system $dst security.selinux
EOF
}
{
	replace "$WORK/task_profiles.json" "$TP"
	replace "$WORK/build.prop" /system/build.prop
	cat <<EOF
mkdir $OVL
sif $OVL mode 040755
ea_set -f $WORK/ctx-system $OVL security.selinux
write $WORK/overlay.apk $OVL/ZX507NoRoundWindows.apk
sif $OVL/ZX507NoRoundWindows.apk mode 0100644
sif $OVL/ZX507NoRoundWindows.apk uid 0
sif $OVL/ZX507NoRoundWindows.apk gid 0
ea_set -f $WORK/ctx-system $OVL/ZX507NoRoundWindows.apk security.selinux
write $ROOT/gsi-init/zx507-audio.rc $RC
sif $RC mode 0100644
sif $RC uid 0
sif $RC gid 0
ea_set -f $WORK/ctx-system $RC security.selinux
write $ROOT/gsi-init/zx507-gps.rc $GPS_RC
sif $GPS_RC mode 0100644
sif $GPS_RC uid 0
sif $GPS_RC gid 0
ea_set -f $WORK/ctx-system $GPS_RC security.selinux
write $ROOT/gsi-init/zx507-gps-guard.sh $GPS_GUARD
sif $GPS_GUARD mode 0100755
sif $GPS_GUARD uid 0
sif $GPS_GUARD gid 2000
ea_set -f $WORK/ctx-phhsu $GPS_GUARD security.selinux
rm $SF
write $WORK/surfaceflinger $SF
sif $SF mode 0100755
sif $SF uid 0
sif $SF gid 2000
ea_set -f $WORK/ctx-sf $SF security.selinux
EOF
} >"$WORK/cmds"

debugfs -w -f "$WORK/cmds" "$OUT" >"$WORK/debugfs.log" 2>&1
if grep -vE '^(debugfs [0-9.]+ \(|debugfs: |Allocated inode: [0-9]+$|$)' "$WORK/debugfs.log" | grep -q .; then
	cat "$WORK/debugfs.log" >&2
	exit 1
fi
e2fsck -fn "$OUT" >/dev/null
echo "$OUT: compat fixes applied"
