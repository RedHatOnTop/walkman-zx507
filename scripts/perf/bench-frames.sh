# Per-gesture framestats: each gesture gets its own gfxinfo reset and dump.
# Optional $1: display scale in per mille of 720x1280 (750 after `wm size 540x960`),
# since `input swipe` takes logical coordinates.
S=${1:-1000}
c() { echo $(($1 * S / 1000)); }
home=$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1 | cut -d/ -f1)
dump() { echo "### $1"; dumpsys gfxinfo $2 framestats | awk '/---PROFILEDATA---/{f=!f; next} f'; }
input keyevent KEYCODE_WAKEUP; input keyevent KEYCODE_HOME; sleep 2
for i in 1 2 3 4 5; do
	dumpsys gfxinfo $home reset >/dev/null; input swipe $(c 360) $(c 1100) $(c 360) $(c 300) 250; sleep 1.2; dump drawer-open $home
	dumpsys gfxinfo $home reset >/dev/null; input keyevent KEYCODE_HOME; sleep 1.2; dump drawer-close $home
done
for i in 1 2 3 4 5; do
	dumpsys gfxinfo com.android.systemui reset >/dev/null; cmd statusbar expand-settings; sleep 1.2; dump qs-expand com.android.systemui
	dumpsys gfxinfo com.android.systemui reset >/dev/null; cmd statusbar collapse; sleep 1; dump qs-collapse com.android.systemui
done
for i in 1 2 3 4 5; do
	dumpsys gfxinfo com.android.systemui reset >/dev/null; input swipe $(c 360) $(c 5) $(c 360) $(c 900) 400; sleep 1.2; dump shade-drag com.android.systemui
	dumpsys gfxinfo com.android.systemui reset >/dev/null; input swipe $(c 360) $(c 1150) $(c 360) $(c 200) 300; sleep 1; dump shade-close com.android.systemui
done
