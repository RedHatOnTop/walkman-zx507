package dev.walkman.zx507.setup;

import android.icu.text.TimeZoneNames;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Locale;

/** What the unit now has, before the home screen. */
final class DonePage extends Page {
    private final ZonePage mZone;

    DonePage(SetupActivity host, ZonePage zone) {
        super(host);
        mZone = zone;
    }

    @Override
    CharSequence title() {
        return mHost.getString(R.string.done_title);
    }

    @Override
    CharSequence subtitle() {
        return mHost.getString(R.string.done_subtitle);
    }

    @Override
    CharSequence nextLabel() {
        return mHost.getString(R.string.start);
    }

    @Override
    View content() {
        LinearLayout box = new LinearLayout(mHost);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(Ui.dp(mHost, 24), Ui.dp(mHost, 8), Ui.dp(mHost, 24), 0);
        LinearLayout card = Ui.card(mHost);
        Locale ui = mHost.locale();
        String zone = mZone.chosen();
        add(card, R.string.done_language, LanguagePage.name(ui, ui, LanguagePage.shared(ui)));
        add(card, R.string.done_zone, ZonePage.city(TimeZoneNames.getInstance(ui), zone) + " (" + ZonePage.gmt(zone) + ")");
        add(card, R.string.done_wifi, WifiPage.status(mHost));
        add(card, R.string.done_debug, mHost.getString(DebugPage.on(mHost) ? R.string.on : R.string.off));
        box.addView(card, Ui.wide(-2));
        return box;
    }

    private void add(LinearLayout card, int label, String value) {
        LinearLayout row = new LinearLayout(mHost);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(Ui.dp(mHost, 44));
        TextView l = Ui.text(mHost, mHost.getString(label), 14, Ui.MUTED);
        TextView v = Ui.text(mHost, value, 15, Ui.TEXT);
        v.setGravity(Gravity.END);
        v.setPadding(Ui.dp(mHost, 12), 0, 0, 0);
        row.addView(l);
        row.addView(v, new LinearLayout.LayoutParams(0, -2, 1));
        if (card.getChildCount() > 0) {
            View rule = new View(mHost);
            rule.setBackgroundColor(Ui.LINE);
            card.addView(rule, Ui.wide(Math.max(1, Ui.dp(mHost, 0.5f))));
        }
        card.addView(row, Ui.wide(-2));
    }
}
