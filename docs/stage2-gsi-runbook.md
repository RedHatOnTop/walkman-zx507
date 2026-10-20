# Stage 2 runbook: Android 13 GSI on the ZX507

Prepared 2026-10-14. **Not executed.** Every step that touches the device waits
for the operator's go. Stage 1 findings and the reasons for this route are in
`android-upgrade-feasibility.md`.

Unit: `icx1295_002`, build 4.06.00, boots slot **b**, bootloader locked,
`sys.oem_unlock_allowed=0` (capture 2026-09-24).

## Inputs (all on disk, verified)

| Item | Path | Check |
|---|---|---|
| GSI | `gsi/system-td-arm64-ab-vanilla-ci-20230905.img.xz` | TrebleDroid `ci-20230905`, android_13.0.0_r73; 641,469,308 bytes = GitHub asset size; SHA-256 in `gsi/SHA256SUMS` |
| GSI, unpacked | (decompress just before flashing) | 1,931,804,672 bytes, raw ext4 (`53 ef` at 1080); system partition is 3,145,728,000 |
| Stock rollback | `extracted/codex-20260924T1406Z/exact-4.06.00-images/` | series `0000` 4.06.00, this unit's fingerprint; `sha256sum -c SHA256SUMS` 9/9 on 2026-09-24 |
| fastboot | `tools/platform-tools/fastboot` | pinned with the 09-24 adb |

TrebleDroid is chosen over Google's own Android 13 GSI because it carries
workarounds for old vendors. Both ship the VNDK 28 snapshot. The arm64 build is
needed because the vendor runs `zygote64_32` and its audio HAL service is 32-bit
(`/vendor/lib/hw/android.hardware.audio@4.0-impl.so` exists only in `lib/`).

## Costs the operator accepts by saying go

- **Unlocking wipes `userdata`.** That is AOSP/NXP standard behaviour, and the
  bootloader carries `fastboot_wipe_data_partition` and `fastboot wiped all.`. Anything
  in internal storage (49.8 GiB, 11 GiB used at capture) is gone. Back it up
  first. The microSD card is not part of `userdata`, but take it out during
  flashing anyway.
- The unit boots with an orange-state warning while unlocked.
- Sony's high-res mixer, `W.ave` player and settings apps are absent on the GSI.
  Sound still goes through Sony's vendor HAL.

## Steps

Gate markers: **[R]** is read-only, **[W]** writes to the device.

0. **[R]** Preflight: `adb devices`, `adb shell getprop ro.boot.slot_suffix`
   (expect `_b`), `getprop ro.build.fingerprint` (expect `.../4.06.00/316...`),
   and battery above 60 %.
1. **[W, operator's hands]** Settings, then Developer options, then **OEM
   unlocking** on. Confirm `adb shell getprop sys.oem_unlock_allowed` reads `1`.
2. **[W]** `adb reboot bootloader`, then **[R]** `fastboot getvar all` and save
   it under `device-capture/`. Look for `unlocked`, `current-slot`,
   `partition-size:system_b`, `max-download-size`.
3. **[W, wipes data]** `fastboot flashing unlock`, then confirm on the device if
   it asks. Answers the open question: if this is refused, try
   `fastboot oem unlock` and record which one worked.
4. **[W]** Disable verification. This flashes the stock `vbmeta.img` with the
   flags set, not a different image:
   `fastboot --disable-verity --disable-verification flash vbmeta_b vbmeta.img`.
   The stock vbmeta carries two command-line descriptors (flags 1 and 2). The
   flag-2 one, `root=PARTUUID=$(ANDROID_SYSTEM_PARTUUID)`, is the one used when
   the hashtree is disabled, so the kernel mounts system without dm-verity.
5. **[W]** `xz -dk` the GSI, then
   `fastboot flash system_b system-td-arm64-ab-vanilla-ci-20230905.img`.
6. **[W]** `fastboot -w`, then `fastboot reboot`. The first boot can take
   several minutes.

## What to measure

1. Boots to the launcher, or how far it gets. If it stalls, take
   `adb logcat -b all` and the console, and stop there.
2. The display panel, touch, Wi-Fi, Bluetooth, buttons and battery.
3. Sound through the headphone jack. Record which HAL loaded and what rate the
   mixer opened at:
   - `adb shell dumpsys media.audio_flinger`: output threads, sample rate, format.
   - `adb shell dumpsys media.audio_policy`: which XML was parsed, the output
     profiles.
4. Play 44.1 kHz, 96 kHz and 192 kHz test files and record the rate the output
   thread reports for each.
5. Only if 3-4 work: swap in the high-res policy XML (vendor is writable while
   verity is off) and repeat 3-4.

## Rollback

Stock images live in `extracted/codex-20260924T1406Z/exact-4.06.00-images/`.
From fastboot:

```
fastboot flash system_b system.img
fastboot flash vbmeta_b vbmeta.img
fastboot flash vendor_b vendor.img    # only if vendor was edited
fastboot -w
fastboot reboot
```

Never run `fastboot flashing lock` while any non-stock image is on the active
slot. Re-locking verifies against Sony's key in RPMB
(`fsl_validate_vbmeta_public_key_rpmb`), so a modified slot would not boot.
Re-lock only after a full stock reflash, and only if wanted.

Per-unit partitions (`nvp`, `idd`, `rca`, `presistdata`) are not touched by any
step above. They are still unbacked (README item 6), and backing them up needs
root. Do that before any experiment that writes beyond `system`/`vbmeta`/`vendor`.
