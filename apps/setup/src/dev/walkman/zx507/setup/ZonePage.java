package dev.walkman.zx507.setup;

import android.app.AlarmManager;
import android.icu.text.TimeZoneNames;
import android.provider.Settings;
import android.text.format.DateFormat;
import android.view.View;
import android.widget.ListView;
import android.widget.TextClock;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TimeZone;

/**
 * The time zone, by city. The language's country comes first (Korean: Seoul alone), every zone
 * a tap further. A Wi-Fi-only unit has nothing to detect a zone from, so a choice turns the
 * automatic zone off; a fresh unit is on GMT until then.
 */
final class ZonePage extends Page {
    private String mZone;
    private boolean mPicked;
    private boolean mAll;

    ZonePage(SetupActivity host) {
        super(host);
    }

    @Override
    CharSequence title() {
        return mHost.getString(R.string.zone_title);
    }

    @Override
    CharSequence subtitle() {
        return mHost.getString(R.string.zone_subtitle);
    }

    @Override
    View header() {
        Locale ui = mHost.locale();
        TextClock clock = new TextClock(mHost);
        String now = "'" + mHost.getString(R.string.zone_now).replace("'", "''") + "' ";
        clock.setFormat12Hour(now + DateFormat.getBestDateTimePattern(ui, "MMMEdhm"));
        clock.setFormat24Hour(now + DateFormat.getBestDateTimePattern(ui, "MMMEdHm"));
        clock.setTextColor(Ui.GOLD);
        clock.setTextSize(15);
        return clock;
    }

    @Override
    View content() {
        String region = mHost.locale().getCountry();
        List<String> local = region.isEmpty() ? new ArrayList<>() : zones(region);
        if (!mPicked) {
            String current = TimeZone.getDefault().getID();
            boolean unset = current.equals("GMT") || current.equals("UTC") || current.startsWith("Etc/");
            mZone = unset && !local.isEmpty() ? local.get(0) : current;
        }
        boolean all = mAll || local.isEmpty();
        Ui.Rows rows = new Ui.Rows(mHost);
        ListView list = Ui.list(mHost, rows);
        Runnable fill = new Runnable() {
            @Override
            public void run() {
                Locale ui = mHost.locale();
                TimeZoneNames names = TimeZoneNames.getInstance(ui);
                List<Ui.Item> items = new ArrayList<>();
                if (all && !local.isEmpty()) {
                    String country = new Locale("", region).getDisplayCountry(ui);
                    items.add(new Ui.Item(mHost.getString(R.string.zone_fewer, country), null, false, true,
                            () -> { mAll = false; mHost.render(0); }));
                }
                Runnable again = this;
                for (String id : all ? zones(null) : local) {
                    items.add(new Ui.Item(city(names, id), detail(id, ui), id.equals(mZone), false, () -> {
                        mZone = id;
                        mPicked = true;
                        apply();
                        again.run();
                    }));
                }
                if (!all) {
                    items.add(new Ui.Item(mHost.getString(R.string.zone_more), null, false, true,
                            () -> { mAll = true; mHost.render(0); }));
                }
                rows.set(items);
            }
        };
        fill.run();
        list.setSelection(Math.max(0, rows.selected() - 2));
        return list;
    }

    @Override
    void onNext() {
        apply();
    }

    private void apply() {
        if (mZone == null || mZone.equals(TimeZone.getDefault().getID())) return;
        Settings.Global.putInt(mHost.getContentResolver(), Settings.Global.AUTO_TIME_ZONE, 0);
        mHost.getSystemService(AlarmManager.class).setTimeZone(mZone);
        TimeZone.setDefault(TimeZone.getTimeZone(mZone));
    }

    String chosen() {
        return mZone != null ? mZone : TimeZone.getDefault().getID();
    }

    static String city(TimeZoneNames names, String id) {
        String city = names.getExemplarLocationName(id);
        return city != null ? city : id.substring(id.lastIndexOf('/') + 1).replace('_', ' ');
    }

    static String gmt(String id) {
        int m = TimeZone.getTimeZone(id).getOffset(System.currentTimeMillis()) / 60000;
        return String.format(Locale.ROOT, "GMT%s%02d:%02d", m < 0 ? "−" : "+", Math.abs(m) / 60, Math.abs(m) % 60);
    }

    private static String detail(String id, Locale ui) {
        TimeZone tz = TimeZone.getTimeZone(id);
        boolean summer = tz.inDaylightTime(new java.util.Date());
        return gmt(id) + " · " + tz.getDisplayName(summer, TimeZone.LONG, ui);
    }

    /** Zones with a city of their own, west to east. */
    private static List<String> zones(String region) {
        Set<String> ids = android.icu.util.TimeZone.getAvailableIDs(
                android.icu.util.TimeZone.SystemTimeZoneType.CANONICAL_LOCATION, region, null);
        List<String> list = new ArrayList<>(ids);
        long now = System.currentTimeMillis();
        list.sort(Comparator.<String>comparingInt(id -> TimeZone.getTimeZone(id).getOffset(now))
                .thenComparing(id -> id));
        return list;
    }
}
