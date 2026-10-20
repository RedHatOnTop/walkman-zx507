# Device capture (read-only, before any modification)

This is the other half of preservation: everything recoverable from the player
itself, captured with plain ADB. **Nothing here modifies the device** -- no
unlock, no flash, no root. Run it before the bootloader is unlocked, because
`fastboot oem unlock` erases userdata and there is no reason to risk a window
where the device is not readable.

## Preconditions

1. On the player: Settings -> About -> tap **Build number** seven times.
2. Settings -> System -> Developer options -> enable **USB debugging**.
3. Connect USB, accept the authorisation prompt, confirm `adb devices`.

## What to capture, and why

| Item | Command | Why it matters |
|---|---|---|
| Full property set | `adb shell getprop > props.txt` | Treble/VNDK/API level, slot suffix, build fingerprint |
| Partition map | `adb shell cat /proc/partitions` | Fixed system/vendor sizes: decides whether a GSI fits |
| Block aliases | `adb shell ls -l /dev/block/by-name` | Slot names, `boot_a/b`, `m4_os_a/b`, vendor oddities |
| Partition sizes | `adb shell 'for d in /dev/block/by-name/*; do echo "$d $(blockdev --getsize64 $d 2>/dev/null)"; done'` | Same, authoritative |
| NVP config | `adb shell cat /vendor/usr/data/icx_nvp.cfg` | **Firmware decryption key (32 key + 16 IV)** |
| Vendor interface | `adb shell ls -l /vendor/etc/vintf` + `adb shell cat /vendor/etc/vintf/manifest.xml` | Treble compliance, HAL inventory |
| HAL binaries | `adb shell ls /vendor/lib64/hw` | Whether the audio HAL exists for a GSI run |
| Mount layout | `adb shell cat /proc/mounts`, `adb shell cat /vendor/etc/fstab*` | system-as-root confirmation, partition flags |
| Kernel info | `adb shell cat /proc/cmdline`, `adb shell cat /proc/version`, `adb shell uname -a` | Boot args, verity/AVB flags |
| Boot log | `adb shell dmesg > dmesg.txt` | Device tree, codec probe, M4 handshake |
| Packages | `adb shell pm list packages -f > packages.txt` | What Sony ships, useful for debloat planning |
| Full bugreport | `adb bugreport bugreport.zip` | Everything above in one archive, with timestamps |

Also worth keeping: a photo or text note of the model number, the region
variant, and the currently installed build number (Settings -> About).

## Handling the key

`/vendor/usr/data/icx_nvp.cfg` contains the firmware decryption key. Treat it as
a secret:

- store it outside git (`secrets/` is ignored by this repository),
- never paste it into an issue, commit, or log,
- it is model-specific, not per-unit: a leaked key decrypts every package for
  that model, so redistribution is worse than useless.

## Then

```bash
scripts/decrypt-upg.sh firmware/NW-ZX500_0003_V4_04_00_NW_WM_FW.UPG \
  --key-file secrets/icx_nvp.cfg -o extracted/zx500_chn_4.04.00.zip
```

Extract `payload.bin` from the resulting zip and run a payload dumper to get the
partition images. Keep the decrypted zips: they are the actual preservation
target, since the `.UPG` originals can always be re-fetched from Sony while the
decrypted content cannot be recovered without the key.
