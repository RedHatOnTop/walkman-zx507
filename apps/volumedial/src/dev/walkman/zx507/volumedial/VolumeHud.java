package dev.walkman.zx507.volumedial;

import android.content.Context;
import android.graphics.PixelFormat;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.WindowManager;
import android.view.animation.AccelerateInterpolator;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;

/**
 * The popup window: SystemUI's volume layer at the right edge, shown and hidden the way
 * Android 9's VolumeDialogImpl did (slide in half its width over 300 ms, out over 250 ms,
 * gone 3 s after the last change).
 */
class VolumeHud {
    static final int HEADSET_NONE = -1;
    private static final int HEADSET_BT = 2;
    private static final int HEADSET_USB = 3;

    // WindowManager.LayoutParams.TYPE_VOLUME_OVERLAY, a hidden constant.
    private static final int TYPE_VOLUME_OVERLAY = 2020;
    private static final long TIMEOUT_MS = 3000;

    private final WindowManager mWindowManager;
    private final FrameLayout mRoot;
    private final DialPanel mPanel;
    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private final Runnable mTimeout = this::hide;
    private final float mSlide;
    private int mVolume = -1;
    private int mHeadset = HEADSET_NONE;
    private boolean mAttached;
    private boolean mShowing;

    VolumeHud(Context context, Runnable onOpenDial) {
        mWindowManager = context.getSystemService(WindowManager.class);
        mPanel = new DialPanel(context);
        mPanel.setOnClickListener(v -> onOpenDial.run());

        // A9's volume_dialog.xml: transparent padding around the panel for its shadow.
        float density = context.getResources().getDisplayMetrics().density;
        int pad = Math.round(20 * density);
        mSlide = 40 * density;
        mRoot = new FrameLayout(context) {
            @Override
            public boolean dispatchTouchEvent(MotionEvent event) {
                if (event.getActionMasked() == MotionEvent.ACTION_OUTSIDE) {
                    hide();
                    return true;
                }
                rescheduleTimeout();
                return super.dispatchTouchEvent(event);
            }
        };
        mRoot.setClipToPadding(false);
        mRoot.setPadding(pad, pad, Math.round(8 * density), pad);
        mRoot.addView(mPanel);
    }

    int getVolume() {
        return mVolume;
    }

    void setVolume(int volume) {
        mVolume = volume;
        update();
        if (mShowing) rescheduleTimeout();
    }

    void setHeadset(int headset) {
        mHeadset = headset;
        update();
    }

    private void update() {
        boolean master = mHeadset != HEADSET_BT && mHeadset != HEADSET_USB;
        mPanel.setVolume(master ? mVolume : -1);
    }

    void applyTheme() {
        mPanel.applyTheme();
    }

    void show() {
        rescheduleTimeout();
        if (mShowing) return;
        mShowing = true;
        if (!mAttached) {
            mWindowManager.addView(mRoot, layoutParams());
            mAttached = true;
            mPanel.setAlpha(0f);
            mPanel.setTranslationX(mSlide);
        }
        mPanel.animate().cancel();
        mPanel.animate().alpha(1f).translationX(0f).setDuration(300)
                .setInterpolator(new DecelerateInterpolator(2f)).start();
    }

    void hide() {
        mHandler.removeCallbacks(mTimeout);
        if (!mShowing) return;
        mShowing = false;
        mPanel.animate().cancel();
        mPanel.animate().alpha(0f).translationX(mSlide).setDuration(250)
                .setInterpolator(new AccelerateInterpolator(2f))
                .withEndAction(() -> {
                    if (!mShowing && mAttached) {
                        mWindowManager.removeViewImmediate(mRoot);
                        mAttached = false;
                    }
                }).start();
    }

    private void rescheduleTimeout() {
        mHandler.removeCallbacks(mTimeout);
        mHandler.postDelayed(mTimeout, TIMEOUT_MS);
    }

    private WindowManager.LayoutParams layoutParams() {
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
                TYPE_VOLUME_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.END | Gravity.CENTER_VERTICAL;
        lp.setTitle("VolumeDial");
        lp.windowAnimations = 0;
        return lp;
    }
}
