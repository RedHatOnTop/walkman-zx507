package dev.walkman.zx507.volumedial;

import android.content.Context;
import android.content.res.TypedArray;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.ContextThemeWrapper;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Sony SystemUI's master-volume row (volume_dialog_row_master.xml), rebuilt from its resources:
 * the value in a 48x28 dp box at 24 dp sans-serif-light, and 16 dp below it a 48 dp meter whose
 * 20 radial ticks light up in sixths of 0-120 (MasterVolumeIconView under the
 * ic_os_volume_meter_template mask). The panel is A9's rounded_bg_full: colorBackgroundFloating,
 * 8 dp corners, 9 dp elevation. Colors come from the system theme, as Sony's came from
 * Utils.getColorAccent().
 */
class DialPanel extends LinearLayout {
    private final Context mBase;
    private final TextView mValue;
    private final Meter mMeter;
    private final GradientDrawable mBackground = new GradientDrawable();
    private int mAccent;
    private int mInactive;
    private int mVolume = -1;

    DialPanel(Context context) {
        super(new ContextThemeWrapper(context, android.R.style.Theme_DeviceDefault));
        mBase = context;
        Context themed = getContext();

        setOrientation(VERTICAL);
        setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = dp(8);
        setPadding(pad, dp(20), pad, dp(20));
        mBackground.setCornerRadius(dp(8));
        setBackground(mBackground);
        setElevation(dp(9));

        mValue = new TextView(themed);
        mValue.setGravity(Gravity.CENTER);
        mValue.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        mValue.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 24);
        mValue.setIncludeFontPadding(false);
        mValue.setMaxLines(1);
        addView(mValue, new LayoutParams(dp(64), dp(28)));

        mMeter = new Meter(themed);
        LayoutParams meter = new LayoutParams(dp(48), dp(48));
        meter.topMargin = dp(16);
        addView(mMeter, meter);
        applyTheme();
    }

    /**
     * Reads the colors again. The app is persistent and starts before the first boot's palette
     * is seeded, and the palette can change at any time after.
     */
    void applyTheme() {
        TypedArray a = new ContextThemeWrapper(mBase, android.R.style.Theme_DeviceDefault)
                .obtainStyledAttributes(new int[] {
                        android.R.attr.colorAccent,
                        android.R.attr.colorBackgroundFloating,
                        android.R.attr.textColorSecondary,
                });
        mAccent = a.getColor(0, 0xFFFFFFFF);
        mBackground.setColor(a.getColor(1, 0xFF000000));
        mInactive = a.getColor(2, 0xFF808080);
        a.recycle();
        setVolume(mVolume);
    }

    /** volume < 0 shows "--" and a dark meter, as Sony did for USB and absolute-volume BT. */
    void setVolume(int volume) {
        mVolume = volume;
        if (volume < 0) {
            mValue.setText("--");
            mValue.setTextColor(mInactive);
            setContentDescription(null);
        } else {
            mValue.setText(String.valueOf(volume));
            mValue.setTextColor(mAccent);
            setContentDescription("Volume " + volume);
        }
        mMeter.set(volume);
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private class Meter extends View {
        private static final int STEPS = 20;
        private static final float START = 132f;
        private static final float UNIT = 13.8f;
        // Sony's inactive ticks: the accent at alpha 97.
        private static final int DIM_ALPHA = 97;

        private final Paint mPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int mLit = -1;

        Meter(Context context) {
            super(context);
            mPaint.setStyle(Paint.Style.STROKE);
            mPaint.setStrokeCap(Paint.Cap.BUTT);
        }

        /** MasterVolumeIconView.setProgress(): a tick per started sixth of the range. */
        void set(int volume) {
            mLit = volume < 0 ? -1 : (volume + 5) / 6;
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float unit = getWidth() / 48f;
            float cx = getWidth() / 2f;
            float cy = getHeight() / 2f;
            float r0 = 12 * unit;
            float r1 = 18 * unit;
            mPaint.setStrokeWidth(1.8f * unit);
            for (int step = 0; step < STEPS; step++) {
                if (mLit < 0) {
                    mPaint.setColor(mInactive);
                } else {
                    mPaint.setColor(mAccent);
                    if (step >= mLit) mPaint.setAlpha(DIM_ALPHA);
                }
                double angle = Math.toRadians(START + UNIT * step + UNIT / 2);
                float cos = (float) Math.cos(angle);
                float sin = (float) Math.sin(angle);
                canvas.drawLine(cx + r0 * cos, cy + r0 * sin, cx + r1 * cos, cy + r1 * sin, mPaint);
            }
        }
    }
}
