package com.android.server.wm;

import android.view.SurfaceControl;

/**
 * Puts a compat-scaled window's scale back after a seamless rotation. compat-scale/
 * SeamlessScaleFix.java calls restore() right after WindowState.finishSeamlessRotation has run
 * SeamlessRotator.finish, which sets the window surface's matrix to identity. updateScaleIfNeeded
 * only sets the matrix when mLastHScale or mLastVScale change, so without this a downscaled app's
 * windows stay drawn at its own size: SystemUI at 0.75 has its navigation and status bars shrunk
 * into the top left 540 px after every rotation that goes through fixed rotation (an app opened,
 * or home shown, in an orientation the display is not in).
 */
final class ZxSeamlessScale {
    private ZxSeamlessScale() {
    }

    static void restore(WindowState w, SurfaceControl.Transaction t) {
        SurfaceControl sc = w.getSurfaceControl();
        if (sc == null || !sc.isValid() || (w.mLastHScale == 1f && w.mLastVScale == 1f)) return;
        t.setMatrix(sc, w.mLastHScale, 0f, 0f, w.mLastVScale);
    }
}
