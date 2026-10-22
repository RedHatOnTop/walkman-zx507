package dev.walkman.zx507.setup;

import android.content.res.Resources;
import android.os.LocaleList;
import android.util.Log;
import android.view.View;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * The system language, applied on the tap: the configuration change re-renders this page and
 * every later one in it. Left-to-right languages only; the pages are laid out for them.
 */
final class LanguagePage extends Page {
    private static final String TAG = "ZX507Setup";
    private static final String[] TAGS = {
        "en-US", "en-GB", "ko-KR", "ja-JP", "zh-CN", "zh-TW", "de-DE", "fr-FR", "es-ES", "it-IT",
        "pt-BR", "nl-NL", "sv-SE", "pl-PL", "ru-RU", "tr-TR", "th-TH", "id-ID", "vi-VN",
    };

    LanguagePage(SetupActivity host) {
        super(host);
    }

    @Override
    CharSequence title() {
        return mHost.getString(R.string.language_title);
    }

    @Override
    CharSequence subtitle() {
        return mHost.getString(R.string.language_subtitle);
    }

    @Override
    View content() {
        Ui.Rows rows = new Ui.Rows(mHost);
        Locale ui = mHost.locale();
        Set<String> present = new HashSet<>();
        for (String s : Resources.getSystem().getAssets().getLocales()) {
            present.add(Locale.forLanguageTag(s).getLanguage());
        }
        List<Ui.Item> items = new ArrayList<>();
        for (String tag : TAGS) {
            Locale l = Locale.forLanguageTag(tag);
            if (!present.contains(l.getLanguage())) continue;
            boolean twice = shared(l);
            String own = name(l, l, twice);
            String in = name(l, ui, twice);
            boolean selected = l.getLanguage().equals(ui.getLanguage()) && l.getCountry().equals(ui.getCountry());
            items.add(new Ui.Item(own, own.equals(in) ? null : in, selected, false, () -> apply(l)));
        }
        rows.set(items);
        android.widget.ListView list = Ui.list(mHost, rows);
        list.setSelection(Math.max(0, rows.selected() - 2));
        return list;
    }

    static String name(Locale l, Locale in, boolean withCountry) {
        String s = l.getDisplayLanguage(in);
        if (withCountry) s += " (" + l.getDisplayCountry(in) + ")";
        return s.isEmpty() ? s : s.substring(0, 1).toUpperCase(in) + s.substring(1);
    }

    static boolean shared(Locale l) {
        int n = 0;
        for (String tag : TAGS) {
            if (Locale.forLanguageTag(tag).getLanguage().equals(l.getLanguage())) n++;
        }
        return n > 1;
    }

    private void apply(Locale l) {
        if (l.equals(mHost.locale())) return;
        try {
            // LocalePicker is what Settings uses; the platform key exempts this app from the
            // hidden-API list and grants CHANGE_CONFIGURATION.
            Class.forName("com.android.internal.app.LocalePicker")
                    .getMethod("updateLocales", LocaleList.class)
                    .invoke(null, new LocaleList(l));
        } catch (ReflectiveOperationException e) {
            Log.w(TAG, "updateLocales", e);
        }
    }
}
