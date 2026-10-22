package dev.walkman.zx507.setup;

import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * Wi-Fi through Settings' own network picker, which knows every kind of network and password;
 * this page shows where the unit stands and reads it again each second while it is up.
 */
final class WifiPage extends Page {
    private static final String PICK_WIFI_NETWORK = "android.net.wifi.PICK_WIFI_NETWORK";

    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private final Runnable mPoll = this::poll;
    private ImageView mIcon;
    private TextView mState;
    private TextView mDetail;
    private boolean mConnected;

    WifiPage(SetupActivity host) {
        super(host);
    }

    @Override
    CharSequence title() {
        return mHost.getString(R.string.wifi_title);
    }

    @Override
    CharSequence subtitle() {
        return mHost.getString(R.string.wifi_subtitle);
    }

    @Override
    CharSequence nextLabel() {
        return mHost.getString(connected() ? R.string.next : R.string.skip);
    }

    @Override
    View content() {
        LinearLayout box = new LinearLayout(mHost);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(Ui.dp(mHost, 24), Ui.dp(mHost, 8), Ui.dp(mHost, 24), 0);

        LinearLayout card = Ui.card(mHost);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        mIcon = new ImageView(mHost);
        card.addView(mIcon, new LinearLayout.LayoutParams(Ui.dp(mHost, 30), Ui.dp(mHost, 30)));
        LinearLayout texts = new LinearLayout(mHost);
        texts.setOrientation(LinearLayout.VERTICAL);
        texts.setPadding(Ui.dp(mHost, 14), 0, 0, 0);
        mState = Ui.text(mHost, "", 16, Ui.TEXT);
        mDetail = Ui.text(mHost, "", 13, Ui.MUTED);
        texts.addView(mState);
        texts.addView(mDetail);
        card.addView(texts, new LinearLayout.LayoutParams(0, -2, 1));
        box.addView(card, Ui.wide(-2));

        TextView choose = Ui.outlined(mHost, mHost.getString(R.string.wifi_choose));
        choose.setOnClickListener(v -> pick());
        LinearLayout.LayoutParams lp = Ui.wide(-2);
        lp.topMargin = Ui.dp(mHost, 16);
        box.addView(choose, lp);
        show();
        return box;
    }

    @Override
    void onShown() {
        mHandler.removeCallbacks(mPoll);
        mHandler.postDelayed(mPoll, 1000);
    }

    @Override
    void onHidden() {
        mHandler.removeCallbacks(mPoll);
    }

    private void poll() {
        boolean was = mConnected;
        show();
        if (was != mConnected) mHost.relabel();
        mHandler.postDelayed(mPoll, 1000);
    }

    private void show() {
        if (mState == null) return;
        mConnected = connected();
        mState.setText(status(mHost));
        mDetail.setText(mConnected ? mHost.getString(R.string.wifi_connected) : "");
        mDetail.setVisibility(mConnected ? View.VISIBLE : View.GONE);
        mIcon.setImageDrawable(new Ui.Glyph(mHost, Ui.Glyph.WIFI, mConnected ? Ui.GOLD : Ui.MUTED));
    }

    private boolean connected() {
        ConnectivityManager cm = mHost.getSystemService(ConnectivityManager.class);
        NetworkCapabilities caps = cm.getNetworkCapabilities(cm.getActiveNetwork());
        return caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
    }

    /** The network's name, or why there is none. NETWORK_SETTINGS lets the name through. */
    static String status(SetupActivity host) {
        WifiManager wm = host.getSystemService(WifiManager.class);
        if (!wm.isWifiEnabled()) return host.getString(R.string.wifi_off);
        ConnectivityManager cm = host.getSystemService(ConnectivityManager.class);
        NetworkCapabilities caps = cm.getNetworkCapabilities(cm.getActiveNetwork());
        if (caps == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            return host.getString(R.string.wifi_none);
        }
        @SuppressWarnings("deprecation")
        String ssid = wm.getConnectionInfo().getSSID();
        if (ssid == null || ssid.equals(WifiManager.UNKNOWN_SSID)) return host.getString(R.string.wifi_connected);
        return ssid.length() > 1 && ssid.startsWith("\"") && ssid.endsWith("\"") ? ssid.substring(1, ssid.length() - 1) : ssid;
    }

    @SuppressWarnings("deprecation")
    private void pick() {
        // A system app may still switch Wi-Fi on itself; the picker would otherwise open on its
        // own switch.
        mHost.getSystemService(WifiManager.class).setWifiEnabled(true);
        try {
            mHost.startActivity(new Intent(PICK_WIFI_NETWORK));
        } catch (ActivityNotFoundException e) {
            mHost.startActivity(new Intent(Settings.ACTION_WIFI_SETTINGS));
        }
    }
}
