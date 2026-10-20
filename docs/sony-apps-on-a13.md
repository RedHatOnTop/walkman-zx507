# Sony's apps on Android 13

Recorded 2026-10-14, static analysis only. The question: can W.music (the
"Music player", `com.sony.walkman.highresmediaplayer`) and the rest of Sony's
apps move to the Android 13 GSI route described in `audio-preserving-upgrade.md`?

## Answer

**Yes for all of Sony's own apps. Settings and SystemUI do not move.** Those two
are Sony-patched AOSP platform apps; the GSI brings its own. Sony's apps need
three kinds of local treatment, done on the user's machine from their own
firmware, never redistributed:

1. **Re-signing** with the GSI's platform key, for the apps that share
   `android.uid.system` and so that all of them are exempt from hidden-API
   enforcement as platform apps. The TrebleDroid GSI uses AOSP's public test key
   (see the audio doc).
2. **The AudioTrack proxy shim** for W.music's native engine
   (`libspmedia_walkman.so`; see the audio doc).
3. **Small bytecode patches** for two Bluetooth spots in W.music and
   IzmAudioManager (below).

## Inventory: 21 Sony apps (plus Settings/SystemUI)

Found by scanning every APK manifest under `system/app`, `system/priv-app`,
`system/product` and `vendor/app` for Sony strings; fields from
apktool-decoded manifests. All target SDK 28.

| App | Package | Shared UID | Native libs used |
|---|---|---|---|
| Music player (W.music) | `com.sony.walkman.highresmediaplayer` | - | `spmedia_walkman`, `spusb_walkman`, `wmmediaplayer_walkman` |
| IzmAudioManager | `com.sony.walkman.izmaudiomanager` | system | - |
| IzmDeviceManager | `com.sony.walkman.izmdevicemanager` | system | - |
| AudioInfoExtractor | `com.sony.walkman.audioinfoextractor` | system | `spmedia_walkman_ex`, `wmmediaplayer_walkman` |
| StorageMonitorService | `com.sony.walkman.storagemonitorservice` | system | - |
| BatteryCtrlService | `com.sony.walkman.batteryctrlservice` | system | - |
| FuncCore | `com.sony.walkman.funccore` | system | - |
| Sound adjustment | `com.sony.walkman.soundeffectapp` | - | - |
| VolumeCtrlPanelApp, VolumeCtrlAlert | `com.sony.walkman.volumectrlpanel`, `.VolumeCtrlAlert` | - | - |
| Guide to quality sound | `com.sony.walkman.highqualitysoundguide` | - | - |
| System updates (automagic) | `com.sony.walkman.systemupdater` | - | - |
| ReginfoView, SonyEula, SonyWizardInteg, In-store Demo | `com.sony.walkman.*` | - | - |
| Help Guide, Headphones (placeholder), LauncherBookmarks, logdumper, PreAppHider | vendor apps | - | - |

The system updater should not move. It would try to install Sony's Android 9
OTAs.

## Framework API check

`scripts/dex-api-check.py` resolves every class, method and field each APK
references outside its own dex against the A13 GSI's boot classpath:
`/system/framework` minus tools and `services.jar`, plus the `javalib` jars of
the 17 APEXes (of 27) that carry one, 43,443 classes in total. A miss would throw at runtime. Misses
are also looked up in Sony's own Android 9 boot classpath, read from
`boot-*.vdex` and `oat/arm64/*.vdex` (compact dex), 22,246 classes.

| App | Unresolved on A13 |
|---|---|
| 19 Sony apps (all but the two below) | **0** |
| W.music | 7: six Bluetooth internals + one `R$integer` that is missing on Android 9 too (dead reference) |
| IzmAudioManager | 6: the same Bluetooth internals |
| Settings | 171 (platform app, built against Android 9 internals) |
| SystemUI | 204 (same) |

The six Bluetooth internals are `IBluetoothA2dp.getActiveDevice`,
`.getConnectedDevices`, `.isAvrcpAbsoluteVolumeSupported`,
`.setAvrcpAbsoluteVolume`, and `IBluetoothAvrcpController.sendVolumeUp/Down`.
They are hidden AIDL methods whose signatures changed by Android 13 (Bluetooth
moved into its own APEX). They only run on Bluetooth absolute-volume paths.

The checker catches link failures only. Reflection was checked by hand in
W.music and IzmAudioManager:

- Storage (`StorageVolume.getState/getUuid/getPath/getId`,
  `StorageManager.getVolumeList/findVolumeById`, `VolumeInfo.getDisk`,
  `DiskInfo.isUsb`), `SystemProperties.get`, `PowerManager.goToSleep`, and the
  `BluetoothCodecConfig` getters and `SOURCE_CODEC_TYPE_LDAC` all exist on A13
  with the same signatures.
- `FileUtils.getFatVolumeId` is gone on A13, but it was already absent on Sony's
  Android 9 and the code falls back (`"FileUtils#getFatVolumeId is not found."`).
- **Real break:** `BluetoothCodecStatus.getCodecsLocalCapabilities()` and
  `getCodecsSelectableCapabilities()` returned `BluetoothCodecConfig[]` on
  Android 9 and return `List` on A13. `BluetoothControl` walks the result with
  `Array.getLength`, outside any `IllegalArgumentException` handler. So the first
  LDAC check with a Bluetooth headphone connected would throw out of the playback
  service. That needs a bytecode patch, converting the List, in the user's local
  copy.

## What Settings and SystemUI carried

Sony's additions inside them are client hooks into Sony services, not
features of their own. In Settings: `izmproperties`, `volumectrlpanel`, and the
`izm.android.properties@1.0` HIDL stubs (8 classes). In SystemUI: those plus
`izmdevicemanager` and `ncambapp` (noise cancelling / ambient), 15 classes. On
the GSI the AOSP versions lack these entry points:

- The Walkman volume panel hook-in. The panel app itself still installs.
- The NC/ambient control in the status bar. It can return as a `TileService`
  quick-settings tile, which is public API.
- Whatever IzmDeviceManager signalled to SystemUI. Unread; needs the device.

## Not settled without the device

- SELinux. The Sony services run as `system_app` and reach the vendor's
  `izm.android.properties` HIDL service. Whether the vendor policy's rules still
  apply under the GSI's platform policy has to be seen in `dmesg`/`logcat`
  denials.
- Behaviour changes for target-28 apps on A13: background starts, notification
  permission, storage access on the SD card. The apps are platform-signed
  priv-apps, which removes most of this, but not by proof.
- Whether `persistent="true"` IzmAudioManager starts and binds before W.music
  does.

## How the install would work

Nothing Sony-made goes into a published artifact. A script run by the user would:

1. Decrypt their own `.UPG` (`scripts/decrypt-upg.sh`) or pull from their device.
2. Copy the Sony APKs and their `/system/lib64` libraries into a working copy of
   the GSI `system.img`.
3. Re-sign with the GSI's platform key.
4. Apply the two bytecode patches and the shim's `DT_NEEDED` rewrite.
5. Add a `privapp-permissions` XML.

Only that script, the shim source and the patches would be published.
