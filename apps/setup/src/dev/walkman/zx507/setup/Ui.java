package dev.walkman.zx507.setup;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * What every page is drawn with: OLED black, a warm white, and W.music's gold (#C0A565, the
 * system palette's seed) for what is chosen and what comes next.
 */
final class Ui {
    static final int BLACK = 0xFF000000;
    static final int SURFACE = 0xFF141312;
    static final int LINE = 0xFF2C2A27;
    static final int TEXT = 0xFFF2EEE6;
    static final int MUTED = 0xFF8D887F;
    static final int GOLD = 0xFFC0A565;
    private static final int PRESS = 0x33C0A565;

    private Ui() {}

    static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
    }

    /**
     * Android breaks Hangul between any two syllables, so a sentence could end on a lone "다.".
     * Word joiners inside each word leave only the spaces to break at (CSS keep-all).
     */
    static CharSequence keepWords(CharSequence s) {
        StringBuilder b = new StringBuilder(s.length() * 2);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (i > 0) {
                char p = s.charAt(i - 1);
                if (!Character.isWhitespace(p) && !Character.isWhitespace(c) && (hangul(p) || hangul(c))) b.append('⁠');
            }
            b.append(c);
        }
        return b;
    }

    private static boolean hangul(char c) {
        return Character.UnicodeScript.of(c) == Character.UnicodeScript.HANGUL;
    }

    static TextView text(Context c, CharSequence s, float sp, int color) {
        TextView t = new TextView(c);
        t.setText(keepWords(s));
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setLineSpacing(0, 1.15f);
        return t;
    }

    static TextView title(Context c) {
        TextView t = text(c, "", 26, TEXT);
        t.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        t.setLineSpacing(0, 1.05f);
        return t;
    }

    static GradientDrawable round(int fill, float radius) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fill);
        d.setCornerRadius(radius);
        return d;
    }

    static Drawable pressable(Drawable content, float radius) {
        return new RippleDrawable(ColorStateList.valueOf(PRESS), content, round(BLACK, radius));
    }

    /** The one gold action of a page. */
    static TextView primary(Context c) {
        TextView b = text(c, "", 15, BLACK);
        b.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        b.setGravity(Gravity.CENTER);
        b.setMinWidth(dp(c, 104));
        b.setPadding(dp(c, 24), 0, dp(c, 24), 0);
        float r = dp(c, 22);
        b.setBackground(new RippleDrawable(ColorStateList.valueOf(0x33000000), round(GOLD, r), null));
        return b;
    }

    static TextView quiet(Context c) {
        TextView b = text(c, "", 15, MUTED);
        b.setGravity(Gravity.CENTER);
        b.setPadding(dp(c, 16), 0, dp(c, 16), 0);
        b.setBackground(pressable(null, dp(c, 22)));
        return b;
    }

    static TextView outlined(Context c, CharSequence s) {
        TextView b = text(c, s, 15, GOLD);
        b.setGravity(Gravity.CENTER);
        float r = dp(c, 22);
        GradientDrawable line = round(BLACK, r);
        line.setStroke(dp(c, 1), GOLD);
        b.setBackground(pressable(line, r));
        b.setMinHeight(dp(c, 44));
        return b;
    }

    static LinearLayout card(Context c) {
        LinearLayout card = new LinearLayout(c);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackground(round(SURFACE, dp(c, 16)));
        card.setPadding(dp(c, 16), dp(c, 14), dp(c, 16), dp(c, 14));
        return card;
    }

    static LinearLayout.LayoutParams wide(int height) {
        return new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height);
    }

    /** A list that fades into the black at its ends instead of showing a bar. */
    static ListView list(Context c, Rows rows) {
        ListView l = new ListView(c);
        l.setDivider(null);
        l.setSelector(new GradientDrawable());
        l.setVerticalScrollBarEnabled(false);
        l.setVerticalFadingEdgeEnabled(true);
        l.setFadingEdgeLength(dp(c, 28));
        l.setAdapter(rows);
        l.setOnItemClickListener((parent, view, position, id) -> {
            Runnable r = rows.get(position).onClick;
            if (r != null) r.run();
        });
        return l;
    }

    static final class Item {
        final CharSequence primary;
        final CharSequence secondary;
        final boolean selected;
        final boolean link;
        final Runnable onClick;

        Item(CharSequence primary, CharSequence secondary, boolean selected, boolean link, Runnable onClick) {
            this.primary = primary;
            this.secondary = secondary;
            this.selected = selected;
            this.link = link;
            this.onClick = onClick;
        }
    }

    static final class Rows extends BaseAdapter {
        private final Context mContext;
        private List<Item> mItems = new ArrayList<>();

        Rows(Context context) {
            mContext = context;
        }

        void set(List<Item> items) {
            mItems = items;
            notifyDataSetChanged();
        }

        Item get(int position) {
            return mItems.get(position);
        }

        int selected() {
            for (int i = 0; i < mItems.size(); i++) {
                if (mItems.get(i).selected) return i;
            }
            return -1;
        }

        @Override
        public int getCount() {
            return mItems.size();
        }

        @Override
        public Object getItem(int position) {
            return mItems.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convert, ViewGroup parent) {
            Row row = convert instanceof Row ? (Row) convert : new Row(mContext);
            row.bind(mItems.get(position));
            return row;
        }
    }

    private static final class Row extends LinearLayout {
        private final TextView mPrimary;
        private final TextView mSecondary;
        private final ImageView mMark;

        Row(Context c) {
            super(c);
            setOrientation(HORIZONTAL);
            setGravity(Gravity.CENTER_VERTICAL);
            setMinimumHeight(dp(c, 56));
            setPadding(dp(c, 24), dp(c, 8), dp(c, 20), dp(c, 8));
            setBackground(pressable(null, 0));
            LinearLayout texts = new LinearLayout(c);
            texts.setOrientation(VERTICAL);
            mPrimary = text(c, "", 16, TEXT);
            mPrimary.setSingleLine();
            mPrimary.setEllipsize(TextUtils.TruncateAt.END);
            mSecondary = text(c, "", 13, MUTED);
            mSecondary.setSingleLine();
            mSecondary.setEllipsize(TextUtils.TruncateAt.END);
            texts.addView(mPrimary);
            texts.addView(mSecondary);
            addView(texts, new LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            mMark = new ImageView(c);
            addView(mMark, new LayoutParams(dp(c, 22), dp(c, 22)));
        }

        void bind(Item item) {
            mPrimary.setText(item.primary);
            mPrimary.setTextColor(item.selected ? GOLD : item.link ? MUTED : TEXT);
            mSecondary.setText(item.secondary);
            mSecondary.setVisibility(TextUtils.isEmpty(item.secondary) ? GONE : VISIBLE);
            mMark.setImageDrawable(item.selected ? new Glyph(getContext(), Glyph.CHECK, GOLD)
                    : item.link ? new Glyph(getContext(), Glyph.CHEVRON, MUTED) : null);
        }
    }

    /** Line glyphs drawn to the density, so no image resources ride along. */
    static final class Glyph extends Drawable {
        static final int CHECK = 0;
        static final int CHEVRON = 1;
        static final int WIFI = 2;

        private final int mShape;
        private final Paint mPaint = new Paint(Paint.ANTI_ALIAS_FLAG);

        Glyph(Context c, int shape, int color) {
            mShape = shape;
            mPaint.setColor(color);
            mPaint.setStyle(Paint.Style.STROKE);
            mPaint.setStrokeWidth(dp(c, shape == WIFI ? 2.2f : 2f));
            mPaint.setStrokeCap(Paint.Cap.ROUND);
            mPaint.setStrokeJoin(Paint.Join.ROUND);
        }

        @Override
        public void draw(Canvas canvas) {
            float w = getBounds().width();
            float h = getBounds().height();
            canvas.save();
            canvas.translate(getBounds().left, getBounds().top);
            Path p = new Path();
            switch (mShape) {
                case CHECK:
                    p.moveTo(w * 0.22f, h * 0.52f);
                    p.lineTo(w * 0.42f, h * 0.72f);
                    p.lineTo(w * 0.80f, h * 0.30f);
                    canvas.drawPath(p, mPaint);
                    break;
                case CHEVRON:
                    p.moveTo(w * 0.40f, h * 0.26f);
                    p.lineTo(w * 0.64f, h * 0.50f);
                    p.lineTo(w * 0.40f, h * 0.74f);
                    canvas.drawPath(p, mPaint);
                    break;
                default:
                    float cx = w / 2, cy = h * 0.82f;
                    for (float r : new float[] {0.26f, 0.48f, 0.70f}) {
                        float rr = r * w;
                        canvas.drawArc(new RectF(cx - rr, cy - rr, cx + rr, cy + rr), 225, 90, false, mPaint);
                    }
                    mPaint.setStyle(Paint.Style.FILL);
                    canvas.drawCircle(cx, cy, mPaint.getStrokeWidth() * 0.9f, mPaint);
                    mPaint.setStyle(Paint.Style.STROKE);
            }
            canvas.restore();
        }

        @Override
        public void setAlpha(int alpha) {
            mPaint.setAlpha(alpha);
        }

        @Override
        public void setColorFilter(ColorFilter filter) {
            mPaint.setColorFilter(filter);
        }

        @Override
        public int getOpacity() {
            return PixelFormat.TRANSLUCENT;
        }
    }
}
