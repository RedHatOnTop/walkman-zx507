# Android 13 on your own NW-ZX507: build and install

This repository ships no image. It is a build kit: scripts that turn TrebleDroid's public
Android 13 GSI and **your unit's own** Sony firmware into a system image and a boot image for
that unit. Sony's apps, libraries, boot animation and ramdisk come from your firmware and stay
on your machine; do not pass the results on.

Status 2026-10-22: one unit runs the release build (`RELEASE=1`), installed clean from
Walkman Manager on 2026-10-21 right after going back to stock with it; the debug build was in
daily use before that. The first-run setup below is in the kit since 2026-10-22; it ran on that
unit as an app, and not yet as the first boot of a clean install.

## What you need

- An NW-ZX507 on firmware 4.06.00. Built and tested with series `0000` (international). Other
  4.06.00 series should carry the same vendor image and Sony apps but are untested. Every step
  that patches a Sony binary checks its hash first and stops on any other.
- A Linux x86_64 host with ~20 GB free on one filesystem (the steps copy with
  `cp --reflink`; on btrfs or XFS the intermediate images cost almost nothing), `bash`,
  `e2fsprogs` (tested with 1.47), `patchelf`, `python3`, `java` 17 or newer, `curl`, `zip`,
  `unzip`, `xz`, `ar`, `openssl`, and Google's platform-tools, unpacked as `tools/platform-tools/` (the scripts take
  `adb` and `fastboot` from there).
- Agreement to the Android SDK License Agreement (https://developer.android.com/studio/terms):
  `scripts/fetch-tools.sh` downloads Google's build-tools 34 only with
  `ANDROID_SDK_LICENSE=accepted`.
- No NDK and no SDK beyond that: our own libraries and VolumeDial come prebuilt from this
  repository's `prebuilt-1` release, pinned in `kit/prebuilt.sha256`
  (`scripts/build-prebuilt.sh` builds the same bytes from source). `KIT_FROM_SOURCE=1` has the
  steps build them instead, with the NDK r27c (`NDK=`) and the SDK's build-tools 35.0.0 and
  android-35 platform (`ANDROID_SDK=`).
- The kernel `Image` from this repository's releases (with its source beside it), or for
  building it yourself an x86_64 Linux host that can compile for ~20 minutes
  (`kernel/build.sh`).
- A backup of everything in internal storage. **Unlocking wipes it.** Take the microSD card
  out while flashing.

## 1. Your firmware

1. On the unit, stock: enable USB debugging, then `scripts/capture-device.sh`. Besides the
   read-only capture it saves `/vendor/usr/data/icx_nvp.cfg` as `secrets/icx_nvp.cfg`: the
   key Sony's firmware files are encrypted with. It is per model; keep it private.
2. `scripts/fetch-firmware.sh` downloads Sony's `.UPG` files and checks their sizes and
   hashes (`firmware/MANIFEST.tsv`).
3. `scripts/decrypt-upg.sh firmware/NW-ZX500_0000_V4_06_00_NW_WM_FW.UPG -o <dir>/ota.zip`
   decrypts and verifies against the file's own SHA-224.
4. `scripts/extract-partition.py <dir>/ota.zip --extract <name> -o <dir>/<name>.img` for
   `boot`, `vbmeta`, `system` and `vendor`.

## 2. The kernel

The stock 4.14 kernel lacks the binder feature Android 13's keystore needs, so a GSI does not
get past first boot on it. `kernel/patches/` adds it (0001), the Himax touch firmware wait
(0003) and exFAT for SD cards (0004).

The release `kernel-4.14.78-zx507-1` has it built: `Image-zx507-4.14.78-1` (sha256
`19c3af6fc902f74a47b73b7320821ba189021362d080e07dbe1e965b12afb336`), with its complete source,
`.config` and `SHA256SUMS` beside it. Download it and go on with step 3 below. To build the
same kernel yourself:

1. Sony's GPL source for this player:
   `https://prodgpl.blob.core.windows.net/download/Audio/20211022/gpl_source.tgz`
   (MD5 `4ea368ef…`, checked by the script).
2. `kernel/build.sh gpl_source.tgz <out>` builds `Image` with Sony's own compiler and the stock
   release string, so the vendor's three modules (`/lib/modules/{wlan,cxd3778gf_dnc_core,icx_nvp_emmc}.ko`
   in `vendor.img`) still load. Check them against the build with
   `kernel/check-modversions.py <out>/Module.symvers 4.14.78-g69dd21e <module.ko>...`.
3. `kernel/repack-boot.py <dir>/boot.img <out>/Image boot-zx507.img` puts that kernel into
   your stock boot image; ramdisk, command line and the partition tail stay as they were.

## 3. The system image

1. `scripts/fetch-tools.sh` downloads the GSI and the host tools, each pinned by sha256.
2. Release build:

   ```
   RELEASE=1 scripts/build-image.sh gsi/system-td-arm64-ab-vanilla-ci-20230905.img \
       <dir>/system.img <dir>/vendor.img system-zx507.img
   ```

   About 3 minutes. Add `KEEP_SU=1` to keep root (TrebleDroid's `su`, reachable from an
   authorized adb shell). Without `RELEASE=1` you get the debug build: a root telnet over USB
   during boot, adb open to any computer, logs mirrored to `/data/zxlog`. Use that only on
   your own desk.
3. `python3 -I scripts/image-manifest.py system-zx507.img` lists every file with its hash,
   mode, owner and SELinux label, for comparing two builds.

## 4. Install

The unit boots slot **b**. Never run `fastboot flashing lock` on a unit with anything but
Sony's own images on it.

1. Stock, Settings → Developer options → **OEM unlocking** on.
2. `adb reboot bootloader`
3. `fastboot flashing unlock`. **This wipes userdata.** The unit shows only the SONY logo
   and does not answer for about 10 minutes; `fastboot getvar unlocked` then reads `yes`.
   It also resets the A/B metadata, so the current slot becomes **a**.
4. `fastboot flash vbmeta_b <out-dir>/vbmeta.img`: `make-install.sh`'s vbmeta is your stock
   one with verity and verification already off. Flashing the plain stock vbmeta instead
   takes `--disable-verity --disable-verification`, which fastboot 37.0.0 fails with
   "Failed to find AVB_MAGIC at offset: 0" (the image is smaller than the partition).
5. `fastboot --set-active=b`
6. `fastboot flash boot_b boot-zx507.img`
7. `fastboot flash system_b system-zx507.img`
8. `fastboot -w` (about 10 minutes), then `fastboot reboot`.

A later boot takes about 80 seconds to the home screen; the first one after `-w` takes longer
(not timed for this build). The first boot sets the defaults once: the black and gold theme,
SystemUI at 0.75 scale and five Quick Settings tiles (`gsi-init/`), and microG's runtime
permissions (Android grants default permissions only then). Then it asks, where AOSP's
Provision went straight to an English home screen on GMT (`apps/setup`): the language; the
time zone, the language's country first (a Wi-Fi-only unit has nothing to detect one from);
Wi-Fi, through Settings' own network picker; and USB debugging, off unless you turn it on. The
home screen then has W.music and Sound adjustment in the dock and nothing else, from the same
app as Launcher3's partner layout. If the unit loops instead, the
bootloader falls back to stock on slot a, which finds Android 13's keys in userdata and asks
for a factory reset; after that, slot a runs stock again.

## Back to stock

`scripts/make-restore.sh <file.UPG> <icx_nvp.cfg> <stock-dir> <out-dir>` puts the four stock
partitions from your UPG in `<out-dir>`, as `unpack-stock.sh` checked them, with an
`install.json` for Walkman Manager's "Back to stock". By hand, with the player in fastboot:

1. `fastboot flash vbmeta_b vbmeta.img`, `fastboot flash boot_b boot.img`,
   `fastboot flash system_b system.img`, `fastboot flash vendor_b vendor.img`: the images as
   the UPG has them, vbmeta with its verification on again.
2. `fastboot --set-active=b`
3. `fastboot -w` (Android 9 cannot read Android 13's userdata), then `fastboot reboot`.

Slot a keeps its stock system through all of this. The bootloader stays unlocked; locking it
erases the player once more and is not part of going back. Run on the unit on 2026-10-21
from Walkman Manager: Sony's 4.06.00 came back on slot b with its stock kernel and files.

## Known issues

- Security patch level 2023-09 (TrebleDroid's last Android 13 build), on a device with Wi-Fi
  and a browser.
- Firefox renders in software: the Vivante GPU offers GLES 2.0 only.
- Status bar icons sit 11 px off.
- A few legacy GB2312 tags still show wrong in W.music (CP949 tags are fixed).
- microG's device registration and Cloud Messaging are off by default, so push messages do
  not arrive until you turn them on in microG settings.
- Transient frames while the screen rotates.
- Untested: Bluetooth audio to a paired headset (A2DP/LDAC), battery life against stock.

## Supported

NW-ZX507 only. The NW-A105 shares the platform and the GPL source but has its own firmware key
and has not been tried.
