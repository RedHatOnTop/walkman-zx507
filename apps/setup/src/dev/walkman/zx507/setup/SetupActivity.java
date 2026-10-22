package dev.walkman.zx507.setup;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.List;
import java.util.Locale;

/**
 * The pages and what is around them: four marks for the steps, the title, the page, and Back
 * and the gold Next at the bottom. Back on the first page does nothing; this is the home
 * screen until the end.
 */
public class SetupActivity extends Activity {
    private static final int STEPS = 4;

    private List<Page> mPages;
    private int mIndex;
    private LinearLayout mMarks;
    private TextView mTitle;
    private TextView mSubtitle;
    private FrameLayout mHeader;
    private FrameLayout mContent;
    private TextView mBack;
    private TextView mNext;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        if (provisioned()) {
            finishSetup();
            return;
        }
        ZonePage zone = new ZonePage(this);
        mPages = List.of(new LanguagePage(this), zone, new WifiPage(this), new DebugPage(this), new DonePage(this, zone));
        if (saved != null) mIndex = saved.getInt("page");
        setContentView(chrome());
        render(0);
    }

    private View chrome() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Ui.BLACK);

        mMarks = new LinearLayout(this);
        mMarks.setPadding(Ui.dp(this, 21), Ui.dp(this, 22), Ui.dp(this, 21), 0);
        for (int i = 0; i < STEPS; i++) {
            View mark = new View(this);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, Ui.dp(this, 3), 1);
            lp.setMargins(Ui.dp(this, 3), 0, Ui.dp(this, 3), 0);
            mMarks.addView(mark, lp);
        }
        root.addView(mMarks, Ui.wide(-2));

        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.VERTICAL);
        head.setPadding(Ui.dp(this, 24), Ui.dp(this, 26), Ui.dp(this, 24), Ui.dp(this, 14));
        mTitle = Ui.title(this);
        mSubtitle = Ui.text(this, "", 14, Ui.MUTED);
        mSubtitle.setPadding(0, Ui.dp(this, 8), 0, 0);
        mHeader = new FrameLayout(this);
        mHeader.setPadding(0, Ui.dp(this, 10), 0, 0);
        head.addView(mTitle);
        head.addView(mSubtitle);
        head.addView(mHeader);
        root.addView(head, Ui.wide(-2));

        mContent = new FrameLayout(this);
        root.addView(mContent, new LinearLayout.LayoutParams(-1, 0, 1));

        LinearLayout bar = new LinearLayout(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(Ui.dp(this, 12), Ui.dp(this, 12), Ui.dp(this, 20), Ui.dp(this, 16));
        mBack = Ui.quiet(this);
        mBack.setOnClickListener(v -> back());
        mNext = Ui.primary(this);
        mNext.setOnClickListener(v -> next());
        bar.addView(mBack, new LinearLayout.LayoutParams(-2, Ui.dp(this, 44)));
        bar.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
        bar.addView(mNext, new LinearLayout.LayoutParams(-2, Ui.dp(this, 44)));
        root.addView(bar, Ui.wide(-2));
        return root;
    }

    /** Draws the current page anew; direction is where it came from (1 next, -1 back, 0 here). */
    void render(int direction) {
        Page page = mPages.get(mIndex);
        for (int i = 0; i < STEPS; i++) {
            mMarks.getChildAt(i).setBackground(Ui.round(i <= mIndex ? Ui.GOLD : Ui.LINE, Ui.dp(this, 2)));
        }
        mTitle.setText(Ui.keepWords(page.title()));
        mSubtitle.setText(Ui.keepWords(page.subtitle()));
        mHeader.removeAllViews();
        View header = page.header();
        mHeader.setVisibility(header == null ? View.GONE : View.VISIBLE);
        if (header != null) mHeader.addView(header);
        mContent.removeAllViews();
        mContent.addView(page.content());
        mBack.setText(R.string.back);
        mBack.setVisibility(mIndex == 0 ? View.INVISIBLE : View.VISIBLE);
        relabel();
        if (direction != 0) {
            mContent.setAlpha(0f);
            mContent.setTranslationX(direction * Ui.dp(this, 28));
            mContent.animate().alpha(1f).translationX(0).setDuration(200).start();
        }
        page.onShown();
    }

    void relabel() {
        mNext.setText(mPages.get(mIndex).nextLabel());
    }

    Locale locale() {
        return getResources().getConfiguration().getLocales().get(0);
    }

    private void next() {
        Page page = mPages.get(mIndex);
        page.onNext();
        if (mIndex == mPages.size() - 1) {
            finishSetup();
            return;
        }
        page.onHidden();
        mIndex++;
        render(1);
    }

    private void back() {
        if (mIndex == 0) return;
        mPages.get(mIndex).onHidden();
        mIndex--;
        render(-1);
    }

    @Override
    public void onBackPressed() {
        back();
    }

    @Override
    public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config);
        if (mPages != null) render(0);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (mPages != null) mPages.get(mIndex).onShown();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (mPages != null) mPages.get(mIndex).onHidden();
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        out.putInt("page", mIndex);
    }

    private boolean provisioned() {
        return Settings.Global.getInt(getContentResolver(), Settings.Global.DEVICE_PROVISIONED, 0) == 1
                && Settings.Secure.getInt(getContentResolver(), "user_setup_complete", 0) == 1;
    }

    /** What Provision did: set up, this activity off for good, and on to the launcher. */
    private void finishSetup() {
        Settings.Global.putInt(getContentResolver(), Settings.Global.DEVICE_PROVISIONED, 1);
        Settings.Secure.putInt(getContentResolver(), "user_setup_complete", 1);
        getPackageManager().setComponentEnabledSetting(new ComponentName(this, SetupActivity.class),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP);
        startActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        finish();
    }
}
