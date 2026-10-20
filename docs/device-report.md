# Device report: NW-ZX507 (icx1295_002)

Captured 2026-09-24 over read-only ADB, before any unlock or modification.
Raw captures: `device-capture/20260924T140409Z/` (a first run was corrupted by
an `adb shell` quoting bug and is kept at `device-capture/20260924T140238Z/` for
reference only).

## Identity

| Property | Value |
|---|---|
| Model / name | `NW-ZX500Series` / `icx1295_002` |
| Serial | `<unit serial>` |
| SoC | `ro.board.platform=imx8`, `ro.boot.soc_type=imx8mm` (NXP i.MX 8M Mini) |
| Android | 9 (SDK 28), first API level 28 |
| Build | `4.06.00` (incremental 316), built 2021-10-20 |
| Fingerprint | `SonyAudio/icx1295_002/icx1295:9/4.06.00/316:user/release-keys` |
| Security patch | 2021-11-01 |
| Kernel | `4.14.78-g69dd21e`, GCC 4.9.x, built 2021-10-20 |
| Locale | ko-KR, Asia/Seoul |
| Active slot | **b** (`ro.boot.slot_suffix=_b`) |
| Bootloader | locked (`ro.boot.flash.locked=1`, `ro.boot.vbmeta.device_state=locked`) |
| AVB | version 1.1, vbmeta size 3264, veritymode `enforcing` |
| SELinux | `Enforcing` |

The installed build matches the archived CDN file `NW-ZX500_0002_V4_06_00_NW_WM_FW.UPG`
(series `_0002`, 907,411,888 bytes) -- so the matching recovery package for this
exact unit is already in `firmware/`.

## Treble / porting prerequisites

| Check | Result | Meaning |
|---|---|---|
| `ro.treble.enabled` | `true` | vendor/framework split is real |
| `ro.vndk.version` | `28` | VNDK 28, i.e. Android 9 vendor interface |
| `ro.product.first_api_level` | `28` | Treble was mandatory at launch |
| `/vendor/etc/vintf/manifest.xml` | present, 10,080 bytes | declares the vendor HALs |
| `/vendor/etc/vintf/compatibility_matrix.xml` | present, 2,018 bytes | framework compatibility declaration |

A GSI (arm64, A/B, Android 9/10) is therefore theoretically viable: unlock,
disable AVB with a blank vbmeta, flash `system_a`, keep Sony's vendor and kernel.

Declared HALs include `android.hardware.audio`, `audio.effect`, `bluetooth`,
`boot`, `cas`, `configstore`, `drm`, `gatekeeper`, `gnss`,
`graphics.allocator/composer/mapper`, `health`, `keymaster`, `light`,
`media.omx`, `memtrack`, `nfc`, `power`, `renderscript`, `sensors`, `usb`,
`usb.gadget`, `wifi`, `wifi.hostapd`, `wifi.supplicant`.

Audio HAL binaries in `/vendor/lib64/hw/`:

| Library | Size |
|---|---|
| `audio.primary.icx1295.so` | 2,728,960 |
| `audio.a2dp.icx1295.so` | 1,994,864 |
| `audio.primary.imx8.so` | 77,760 |
| `audio.primary.default.so` | 68,864 |
| `audio.usb.default.so` | 68,936 |
| `audio.r_submix.default.so` | 69,696 |
| `audio.stub.imx8.so` | 77,152 |

The board-specific `audio.primary.icx1295.so` is Sony's DAP audio HAL. It lives
in `/vendor`, so a GSI would keep using it as long as the HAL interfaces match.

## Storage

Partition map (`/dev/block/by-name`, all on `mmcblk2`):

```
dtbo_a p1    dtbo_b p2    boot_a p3    boot_b p4    system_a p5  system_b p6
misc p7      metadata p8  presistdata p9  vendor_a p10  vendor_b p11
fbmisc p12   vbmeta_a p13 vbmeta_b p14 nvp p15      var p16
opt1 p17     opt2 p18     opt3 p19     boot_logo p20 idd p21   rca p22
bootloader_a p23  bootloader_b p24  m4_os_a p25  m4_os_b p26
rsv_boot p27 userdata p28
```

Mounted filesystem sizes (`df`):

| Mount | Backing device | Size | Used | Free |
|---|---|---|---|---|
| `/` (system, system-as-root) | `/dev/root` | 2,975,880 KiB (~2.84 GiB) | 2,110,996 KiB (72%) | 848,500 KiB |
| `/vendor` (dm-verity) | `/dev/block/dm-1` | 195,148 KiB (~190 MiB) | 90,336 KiB | 100,784 KiB |
| `/data` | `mmcblk2p28` | 52,267,164 KiB (~49.8 GiB) | 11,578,088 KiB | 40,541,620 KiB |
| external SD | `/mnt/media_rw/3564-3463` | 124,835,840 KiB (~119 GiB) | 84,922,752 KiB (69%) | 39,913,088 KiB |

`/proc/partitions`, `/proc/cmdline`, `/proc/asound/*` and `dmesg` are denied to
the shell, so exact partition sizes could not be read from the device. GSI
sizing has to come from the OTA payload metadata (once decryption works) or from
`fastboot getvar partition-size:<name>`.

The fstab confirms A/B and system-as-root:

```
/dev/block/by-name/system    /      ext4  ro,barrier=1  wait,slotselect
/dev/block/by-name/userdata  /data  ext4  ...           wait,formattable,quota,fileencryption=software,reservedsize=128M
/dev/block/zram0             none   swap  defaults      zramsize=536870912
```

## Key material on the device

`/vendor/usr/data/` holds five config files:

| File | Size | Notes |
|---|---|---|
| `icx_nvp.cfg` | 1,236 | NVP block; commented sections with quoted values |
| `icx_nvp_destination.cfg` | 521 | destination/region table |
| `icx_nvp_color.cfg` | 75 | colour variant |
| `icx_nvp_hp.cfg` | 38 | headphone variant |
| `icx_cts_list.cfg` | 69 | CTS list |

`icx_nvp.cfg` sections (markers only): `_NVP_ERASEALL_`, `_MODEL_ID_`, `_SPS_`,
`_CLV_`, `_INS_`, `_BMD_`, `_UMS_`, `_UPS_`, `_FVI_`, `_FPI_`, `_SER_`, `_PCD_`,
`_KAS_`, `_UBP_`. Every value is quoted.

The section commented `#@ Key` is **`_KAS_`**, whose value is exactly **48
characters** -- matching the community documentation ("48 character long ASCII
text; the first 32 bytes are the AES key and the next 16 bytes are the IV").
This value is **verified working**: it decrypts the `.UPG` packages and
reproduces each one's embedded SHA-224. `_UBP_` is a 32-character value commented
`#@ U-boot pass...`.

`icx_nvp.cfg` is a shell script fragment: `/vendor/xbin/init_nvp` sources it
(`. /vendor/usr/data/icx_nvp.cfg`) and then calls `nvp`, `nvpflag` and `nvpstr`
to write individual fields into the NVP partition. Those three binaries are not
present in the running system -- they exist only in the `init`/`diag` boot modes.

All captured secrets live in `secrets/` (mode 0700/0600, git-ignored).

## Update path (from Sony's own updater)

Package `com.sony.walkman.systemupdater`, APK at
`/system/priv-app/automagic/automagic.apk` (997 KB dex, pure Java, no native
libraries). Decompiled with apktool; see the decryption section of
`firmware-inventory.md` for the exact algorithm.

Flow: `NW_WM_FW.UPG` → verify `NWWM` magic → AES-256-CBC/PKCS#5 decrypt from
offset 128 (key from the IZM property `ro.updater.info`) → verify SHA-224 of the
plaintext against the header → write `/data/ota_package/NW_WM_FW.zip` → unpack
`payload.bin` + `payload_properties.txt` → hand to `update_engine` via
`update_engine_client applyPayload`.

Access facts relevant to anyone repeating this:

| Item | Status |
|---|---|
| `/system/priv-app/automagic/automagic.apk` | readable, `adb pull` works, no root needed |
| `lshal` shows `izm.android.properties@1.0::IProperties/default` | listed, running as pid 3141 |
| Calling that HAL from shell | SELinux-denied (`properties_hwservice`), logged in logcat |
| `getprop ro.updater.info` | empty -- the IZM store is not the Android property store |
| `/data/ota_package/` | permission denied to shell |
| Updater logging | tag `WMU_dec` logs only the plaintext digest, never key material |
| `/vendor/lib64/libizmproperties.so`, `/vendor/bin/hw/*` | content reads denied (only listings work) |
| `/vendor/xbin/diag_main` | 1.7 MB Sony diagnostic binary linking OpenSSL; content read denied, so its CLI could only be partially enumerated via on-device `strings` |

Boot modes: `/vendor/xbin/tool_switcher` dispatches on `ro.boot.mode` --
`init` runs `start_initialize` (inserts `icx_nvp_emmc.ko`, writes NVP from the
cfg files), `diag` runs `start_diag` (mounts `userdata`, `var`, `opt1`-`opt3`,
enables debugfs, runs `diag_main`), anything else starts recovery. These modes
are the vendor's service interface to NVP and are the only place where the
`nvp`/`nvpflag`/`nvpstr` tools exist.

## Outcome

The IZM route turned out to be unnecessary. The same 48 bytes the updater reads
as `ro.updater.info` are also present on disk as `_KAS_` in
`/vendor/usr/data/icx_nvp.cfg`, which shell can read. Using them, all seven
archived `.UPG` packages decrypt and self-verify against their embedded SHA-224.
The stock images are extracted under
`extracted/codex-20260924T1406Z/exact-4.06.00-images/` and were independently
re-verified here (hashes, boot header, system fingerprint). See
`docs/firmware-inventory.md` for the recipe and the two mistakes that delayed it.
