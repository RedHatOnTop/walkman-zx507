package dev.walkman.zx507.setup;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Never called: Launcher3 finds its partner package by this receiver and reads its resources. */
public class LauncherPartner extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {}
}
