#!/system/bin/sh
# Bind the buffer-orphaning copy of the vendor GLES library
# (scripts/vivante-orphan.py) over the original before SurfaceFlinger and
# zygote start. init may only mount on vendor_configs_file, not on
# same_process_hal_file, so this runs as phhsu_daemon. The copy is a patch of
# one exact vendor build: if the vendor library is anything else, leave it.

VENDOR=/vendor/lib64/egl/libGLESv2_VIVANTE.so
PATCHED=/system/etc/zx507/libGLESv2_VIVANTE.so
SHA256=a843eecd756e9e4bd3daa3299b2d368021641be27e2253c4aed833d90d5d43d1

if [ "$(sha256sum $VENDOR | cut -d' ' -f1)" != $SHA256 ]; then
	echo "zx507-gpu: $VENDOR is not the 4.06.00 build, not replaced" >/dev/kmsg
	exit 0
fi
if mount -o bind $PATCHED $VENDOR; then
	echo "zx507-gpu: $VENDOR replaced by $PATCHED" >/dev/kmsg
else
	echo "zx507-gpu: bind mount failed" >/dev/kmsg
fi
