package dev.walkman.zx507.volumedial;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Starts the process when the app is not running as persistent (a /data install). */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {}
}
