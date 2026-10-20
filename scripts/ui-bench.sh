# UI jank bench, run on the unit: the same scripted gestures every time, then
# dumpsys gfxinfo for the app that drew them (launcher all-apps open/scroll,
# QS shade expand/collapse, Settings list scroll). Compare runs by "Janky
# frames" and "Frame deadline missed"; with SurfaceFlinger's app budget at
# 33.3 ms the legacy (>16 ms) count no longer means a missed frame. Run it
# twice and keep the second, the first warms caches up.
#
# Usage: adb push scripts/ui-bench.sh /data/local/tmp/ && adb shell sh /data/local/tmp/ui-bench.sh
# UI jank bench: the same scripted gestures each run, gfxinfo per app.
home=$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1 | cut -d/ -f1)
report() { dumpsys gfxinfo $1 > /data/local/tmp/gfx.txt; awk "/Total frames rendered/{f=1} f&&/Total frames|Janky|50th|90th|95th|99th|Slow UI|Slow bitmap|Slow issue|Frame deadline|Number High input/{print} /^$/{if(f)exit}" /data/local/tmp/gfx.txt; }
input keyevent KEYCODE_WAKEUP; input keyevent KEYCODE_HOME; sleep 2
echo "== launcher $home"; dumpsys gfxinfo $home reset >/dev/null
for i in 1 2 3 4 5; do input swipe 360 1100 360 300 250; sleep 1.2; input swipe 360 400 360 1100 250; sleep 0.6; input swipe 360 400 360 1100 250; sleep 1.2; done
input keyevent KEYCODE_HOME; sleep 1; report $home
echo "== systemui"; dumpsys gfxinfo com.android.systemui reset >/dev/null
for i in 1 2 3 4 5; do cmd statusbar expand-settings; sleep 1.2; cmd statusbar collapse; sleep 1; done
report com.android.systemui
echo "== settings"; am start -W -a android.settings.SETTINGS >/dev/null; sleep 1.5; dumpsys gfxinfo com.android.settings reset >/dev/null
for i in 1 2 3 4 5; do input swipe 360 1100 360 300 200; sleep 0.8; input swipe 360 300 360 1100 200; sleep 0.8; done
report com.android.settings
input keyevent KEYCODE_HOME
