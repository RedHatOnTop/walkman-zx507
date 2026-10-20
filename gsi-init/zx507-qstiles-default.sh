#!/system/bin/sh
# Quick Settings starts with the five tiles of gsi-overlays/qstiles. On a
# debuggable build SystemUI appends its memory tile (dbg:mem) to that default
# and stores the list before boot completes, so the list is written once here
# without it. Tiles the owner arranges later are left alone.

[ "$(getprop persist.zx507.qs_tiles_default)" = 1 ] && exit 0
case "$(settings get secure sysui_qs_tiles)" in
null | internet,bt,dnd,rotation,battery,dbg:mem)
	settings put secure sysui_qs_tiles internet,bt,dnd,rotation,battery
	log -p i -t zx507-qstiles "Quick Settings set to internet,bt,dnd,rotation,battery"
	;;
esac
setprop persist.zx507.qs_tiles_default 1
