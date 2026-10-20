#!/system/bin/sh
# Seed the system palette with W.music's champagne gold on the first boot.
#
# SystemUI's ThemeOverlayController builds the accent and neutral palettes
# from theme_customization_overlay_packages, and from the wallpaper while it
# is unset. A preset seed has no build-time default, so it is written once
# here; ThemeOverlayController watches the setting and applies it live. A
# style picked later in Wallpaper & style replaces it and is left alone.
# gsi-overlays/blackgold then turns the dark theme's backgrounds black.

[ "$(settings get secure theme_customization_overlay_packages)" = null ] || exit 0
settings put secure theme_customization_overlay_packages \
	'{"android.theme.customization.system_palette":"C0A565","android.theme.customization.accent_color":"C0A565","android.theme.customization.color_source":"preset","android.theme.customization.theme_style":"TONAL_SPOT"}'
log -p i -t zx507-theme "system palette seeded with #C0A565"
