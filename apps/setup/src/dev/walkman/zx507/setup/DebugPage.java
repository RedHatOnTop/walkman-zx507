package dev.walkman.zx507.setup;

import android.content.res.ColorStateList;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;

/**
 * USB debugging, off unless the owner turns it on. A release image has no adb key of its own
 * (ro.adb.secure=1), so the first computer still has to be allowed on the unit.
 */
final class DebugPage extends Page {
    DebugPage(SetupActivity host) {
        super(host);
    }

    @Override
    CharSequence title() {
        return mHost.getString(R.string.debug_title);
    }

    @Override
    CharSequence subtitle() {
        return mHost.getString(R.string.debug_subtitle);
    }

    @Override
    View content() {
        LinearLayout box = new LinearLayout(mHost);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(Ui.dp(mHost, 24), Ui.dp(mHost, 8), Ui.dp(mHost, 24), 0);

        LinearLayout card = Ui.card(mHost);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setMinimumHeight(Ui.dp(mHost, 60));
        TextView label = Ui.text(mHost, mHost.getString(R.string.debug_switch), 16, Ui.TEXT);
        card.addView(label, new LinearLayout.LayoutParams(0, -2, 1));
        Switch toggle = new Switch(mHost);
        int[][] states = {{android.R.attr.state_checked}, {}};
        toggle.setThumbTintList(new ColorStateList(states, new int[] {Ui.GOLD, 0xFFB8B3AA}));
        toggle.setTrackTintList(new ColorStateList(states, new int[] {0x80C0A565, Ui.LINE}));
        toggle.setChecked(on(mHost));
        toggle.setOnCheckedChangeListener((v, checked) -> set(checked));
        card.addView(toggle);
        card.setOnClickListener(v -> toggle.toggle());
        card.setBackground(Ui.pressable(card.getBackground(), Ui.dp(mHost, 16)));
        box.addView(card, Ui.wide(-2));

        TextView note = Ui.text(mHost, mHost.getString(R.string.debug_note), 13, Ui.MUTED);
        note.setPadding(Ui.dp(mHost, 4), Ui.dp(mHost, 14), Ui.dp(mHost, 4), 0);
        box.addView(note, Ui.wide(-2));
        return box;
    }

    static boolean on(SetupActivity host) {
        return Settings.Global.getInt(host.getContentResolver(), Settings.Global.ADB_ENABLED, 0) == 1;
    }

    private void set(boolean on) {
        if (on) {
            Settings.Global.putInt(mHost.getContentResolver(), Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 1);
        }
        Settings.Global.putInt(mHost.getContentResolver(), Settings.Global.ADB_ENABLED, on ? 1 : 0);
    }
}
