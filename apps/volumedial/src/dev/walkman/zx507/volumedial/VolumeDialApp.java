package dev.walkman.zx507.volumedial;

import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.content.res.Configuration;
import android.os.IBinder;
import android.os.Parcel;
import android.os.PowerManager;
import android.os.RemoteException;
import android.util.Log;

/**
 * Follows Sony's master volume and shows {@link VolumeHud} on a volume key.
 *
 * VolumeCtrlPanelApp's MasterVolumeReceiver sends VOLUME_KEY_PRESSED before it adjusts the
 * volume, and MasterVolumeController sends MASTER_VOLUME_CHANGED with the new value after.
 * Both are protected by PERM_MASTER_VOLUME, a normal permission. MASTER_VOLUME_GUI_STARTED and
 * _FINISHED bracket the big dial (MasterVolumeActivity), which replaces the popup while it is up.
 */
public class VolumeDialApp extends Application {
    static final String TAG = "VolumeDial";

    private static final String PANEL = "com.sony.walkman.volumectrlpanel";
    private static final String PERM = PANEL + ".PERM_MASTER_VOLUME";
    private static final String ACTION_KEY = "com.sony.walkman.intent.action.VOLUME_KEY_PRESSED";
    private static final String ACTION_VOLUME = "com.sony.walkman.intent.action.MASTER_VOLUME_CHANGED";
    private static final String ACTION_HEADSET = "com.sony.walkman.intent.action.CURRENT_HEADSET_CHANGED";
    private static final String ACTION_GUI_STARTED = "com.sony.walkman.intent.action.MASTER_VOLUME_GUI_STARTED";
    private static final String ACTION_GUI_FINISHED = "com.sony.walkman.intent.action.MASTER_VOLUME_GUI_FINISHED";

    // IMasterVolumeService (VolumeCtrlPanelApp), from its generated stub.
    private static final String DESCRIPTOR = PANEL + ".IMasterVolumeService";
    private static final int TX_GET_MASTER_VOLUME = 4;
    private static final int TX_GET_CURRENT_HEADSET = 12;

    // MasterVolumeController.notifyMasterVolume(type): 1 after a key press.
    private static final int OPERATION_RELATIVE = 1;

    private VolumeHud mHud;
    private PowerManager mPower;
    private IBinder mService;
    private boolean mDialShowing;

    private final ServiceConnection mConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder service) {
            mService = service;
            refresh();
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            mService = null;
        }
    };

    private final BroadcastReceiver mReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            switch (intent.getAction()) {
                case ACTION_KEY:
                    if (mService != null) refresh();
                    if (!mDialShowing && mPower.isInteractive()) mHud.show();
                    break;
                case ACTION_VOLUME:
                    mHud.setVolume(intent.getIntExtra("volume", mHud.getVolume()));
                    if (intent.getIntExtra("type", 0) == OPERATION_RELATIVE
                            && !mDialShowing && mPower.isInteractive()) {
                        mHud.show();
                    }
                    break;
                case ACTION_HEADSET:
                    mHud.setHeadset(intent.getIntExtra("headset", VolumeHud.HEADSET_NONE));
                    break;
                case ACTION_GUI_STARTED:
                    mDialShowing = true;
                    mHud.hide();
                    break;
                case ACTION_GUI_FINISHED:
                    mDialShowing = false;
                    break;
                case Intent.ACTION_SCREEN_OFF:
                    mHud.hide();
                    break;
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        mPower = getSystemService(PowerManager.class);
        mHud = new VolumeHud(this, this::openDial);

        IntentFilter sony = new IntentFilter();
        sony.addAction(ACTION_KEY);
        sony.addAction(ACTION_VOLUME);
        sony.addAction(ACTION_HEADSET);
        sony.addAction(ACTION_GUI_STARTED);
        sony.addAction(ACTION_GUI_FINISHED);
        registerReceiver(mReceiver, sony, PERM, null, Context.RECEIVER_EXPORTED);
        registerReceiver(mReceiver, new IntentFilter(Intent.ACTION_SCREEN_OFF),
                Context.RECEIVER_NOT_EXPORTED);

        Intent service = new Intent(PANEL + ".MasterVolumeService")
                .setComponent(new ComponentName(PANEL, PANEL + ".MasterVolumeService"));
        if (!bindService(service, mConnection, Context.BIND_AUTO_CREATE)) {
            Log.w(TAG, "cannot bind " + service.getComponent());
        }
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // Also how an overlay change (a new Monet palette) reaches a running process.
        mHud.applyTheme();
    }

    private void refresh() {
        try {
            mHud.setHeadset(call(TX_GET_CURRENT_HEADSET));
            mHud.setVolume(call(TX_GET_MASTER_VOLUME));
        } catch (RemoteException e) {
            Log.w(TAG, "IMasterVolumeService", e);
        }
    }

    private int call(int code) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(DESCRIPTOR);
            mService.transact(code, data, reply, 0);
            reply.readException();
            return reply.readInt();
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    private void openDial() {
        mHud.hide();
        Intent dial = new Intent()
                .setComponent(new ComponentName(PANEL, PANEL + ".MasterVolumeActivity"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(dial);
        } catch (RuntimeException e) {
            Log.w(TAG, "cannot open " + dial.getComponent(), e);
        }
    }
}
