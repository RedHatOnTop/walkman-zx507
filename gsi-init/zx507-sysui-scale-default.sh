#!/system/bin/sh
# Render SystemUI (status bar, shade, QS, navigation bar) at 0.75 scale from
# the first boot on. The GC7000NanoUltra is bound by the pixels it fills
# (devlog 2026-10-16); the compat downscale lays SystemUI's windows out at
# 540x960 / 270 dpi and the hardware composer scales them to the panel without
# client composition. Everything else stays at 720x1280: Sony's apps size
# their screens in panel pixels and break at any other display size (devlog
# 2026-10-17). SystemUI.apk carries scripts/SysuiCompatFix.java for Android
# 13 scaling its resources twice. Applied once; `am compat reset` afterwards
# is left alone.

[ "$(getprop persist.zx507.sysui_scale_default)" = 1 ] && exit 0
am compat enable DOWNSCALED com.android.systemui
am compat enable DOWNSCALE_75 com.android.systemui
setprop persist.zx507.sysui_scale_default 1
log -p i -t zx507-sysui-scale "SystemUI rendered at 0.75"
