# Newer Android on the NW-ZX507 / NW-A105: stage 1 (no device)

Recorded 2026-10-14. Question from the operator: can the ZX507 (and its twin, the
A105) run an Android newer than 9? Stage 1 answers four questions from Sony's
official update files only, with a file path or property line behind each answer.
No device was touched; the device step waits for the operator.

Sources: the ZX500 4.06.00 images already extracted and hash-verified on
2026-09-24 (`extracted/codex-20260924T1406Z/exact-4.06.00-images/`, this unit's
fingerprint), read with `debugfs` and `avbtool` without mounting. Device-side
values quoted for comparison come from the 2026-09-24 read-only capture
(`device-capture/20260924T140409Z/`).

## Verdict

**Feasible, along two different routes, and only one of them keeps Sony's sound.**

| Route | What it is | Ceiling | Sony DSP (DSEE AI, DC Phase Linearizer, Vinyl, EQ) | Hi-res output |
|---|---|---|---|---|
| A. GSI on Sony's vendor + stock 4.14 kernel | flash an AOSP-based GSI to `system_b`, keep `vendor`/`boot` | **Android 13** within AOSP's own compatibility rules; 14+ only with community backports (unverified) | kept: it lives in the vendor HAL | lost by default: Sony's AudioFlinger/AudioPolicy patches live in `system`. Partly recoverable by editing the vendor policy XML; needs a device test |
| B. Full rebuild on NXP's i.MX 8M Mini BSP | new kernel, new vendor, own audio HAL from Sony's GPL codec driver | Android 14-16 (NXP ships BSPs for the 8M Mini EVK) | lost unless Sony's legacy HAL blob is wrapped | Android 14's bit-perfect path is available, but only to an AIDL audio HAL, which would have to be written |

Route A is the cheap first experiment and can be undone by reflashing the stock
images held here. Route B is the one that actually delivers "newer Android with
bit-perfect", and it is a multi-month port.

## 1. Vendor partition, Treble, VNDK

All three are present.

| Evidence | Source |
|---|---|
| vendor is its own partition: 209,715,200 bytes (200 MiB), slots `vendor_a`/`vendor_b` | OTA manifest (`docs/static-analysis.md` §1); `by_name.txt` p10/p11 |
| `ro.treble.enabled=true` | `system.img:/system/build.prop` line 48 |
| `ro.vndk.version=28` | `vendor.img:/default.prop` line 4 |
| `ro.product.first_api_level=28` | `vendor.img:/build.prop` line 42 |
| `<manifest version="1.0" type="device" target-level="3">` | `vendor.img:/etc/vintf/manifest.xml` |
| system-as-root, A/B (`/  ext4 ... wait,slotselect`) | `docs/device-report.md` fstab |

What that buys, checked against AOSP itself (not forum claims):

| AOSP release branch | GSI ships VNDK 28 (`PRODUCT_EXTRA_VNDK_VERSIONS`) | framework still has `compatibility_matrix.3.xml` | `kernel/configs` still has `p/android-4.14` |
|---|---|---|---|
| android11-release | 28 29 | yes | yes |
| android12-release | 28 29 30 | yes | yes |
| android13-release | 28 29 30 | yes | **yes** |
| android14-release | 29 30 31 | **no** (starts at `.4`) | **no** (`p/` removed; 4.14 remains only under `q/`, `r/`) |

Read with `curl` from `android.googlesource.com` (gitiles `?format=JSON`/`TEXT`)
on 2026-10-14. Android 13 is the last release that still officially accepts an
Android 9 vendor (FCM level 3) on a 4.14 kernel. Android 14 removed the VNDK 28
snapshot, the level-3 matrix and the level-3 kernel configs together, so anything
newer on route A depends on community patches that this stage did not verify.

## 2. Where Sony's audio stack lives

Split across all three layers. This is the central finding, because a GSI keeps
only two of them.

**Kernel** (kept by both routes if the stock kernel stays):

- `CONFIG_SND_SOC_CXD3778GF=y`, `CONFIG_SND_SOC_IMX_CXD3778GF=y`: the codec
  driver (the S-Master HX path) is built into the kernel
  (`docs/static-analysis.md` §4).
- `vendor.img:/lib/modules/cxd3778gf_dnc_core.ko`: companion module.
- Sony's GPL drop carries the driver source, `sound/soc/codecs/cxd3778gf/`
  (devlog 2026-09-24), which is what route B would port.

**Vendor** (kept by a GSI):

- `vendor.img:/lib64/hw/audio.primary.icx1295.so` (2,728,960 bytes) plus the
  32-bit copy, loaded through AOSP's `android.hardware.audio@4.0-impl.so`;
  `vintf/manifest.xml` declares `android.hardware.audio` **4.0** over hwbinder.
- The DSP runs inside that HAL. Its strings include `izm_dsee_ai`,
  `enable_dsee_highres: %d`, `file_path_dsee_bin: %s`,
  `EffectInitDPFDCPhaseLinearizer`, `EffectInitVinyl`, `E:Eq10`,
  `izm_eq_tone_band_bass`, `headphone smaster btl gain mode`,
  `AUDIO_OUTPUT_FLAG_DIRECT_PCM`, `AlsaForNxpLpa`.
- DSEE AI model files for both boards: `vendor.img:/etc/DseeAi_ICX1295.{bin,dcfg}`
  and `DseeAi_ICX1293.{bin,dcfg}`.
- Two policy files: `etc/audio_policy_configuration.xml` (primary output
  `PCM_16_BIT` at `samplingRates="48000"` only) and
  `etc/audio_policy_configuration_highres.xml` (primary output 16- and 32-bit at
  44.1-192 kHz). Both also declare a `DIRECT|COMPRESS_OFFLOAD` port with PCM up to
  384 kHz and DSD64-256.
- Properties: `persist.vendor.audio.mixerthread.res=std`,
  `persist.vendor.lpa.buffer.time_ms=20000`, `audio.offload.disable=1`
  (`vendor.img:/build.prop` lines 45-57).

**System** (replaced by a GSI, so this is what gets lost):

- `system.img:/system/lib64/libaudioflinger.so` is Sony-modified. Strings:
  `izmFilterReservedParameters`, `izmFilterVolumeParameters`, `izm_master_volume`,
  `izm_source_direct`, `izm_output_device`, `persist.vendor.audio.mixerthread.res`,
  `vendor.audio.lpa.enable`.
- `system.img:/system/lib64/libaudiopolicymanagerdefault.so` is Sony-modified.
  Strings: `audio_policy_configuration_highres.xml`,
  `persist.vendor.audio.mixerthread.res`, and a non-AOSP method
  `AudioPolicyManager::isPrimaryOutputHighResFormat`.
- `system.img:/system/lib64/libaudioclient.so` reads `vendor.audio.lpa.enable`.
- Apps: `HighResMediaPlayerApp`, `IzmAudioManager`, `IzmDeviceManager`,
  `AudioInfoExtractor` in `/system/priv-app` (`docs/static-analysis.md` §6).

Inference, not yet tested: Sony's policy manager picks the `_highres` XML from
`mixerthread.res`, and the `izm_*` keys reach the HAL as `setParameters` strings
filtered by AudioFlinger. Under a stock AOSP framework the policy manager loads
the plain `audio_policy_configuration.xml`, so the primary mixer runs at
48 kHz/16-bit and every track is resampled. That matches Sony's own explanation
for never shipping an OS update. Two partial fixes that need the device to
evaluate:

1. Edit the vendor copy of `audio_policy_configuration.xml` to the high-res
   profile (vendor is writable once AVB is off).
2. Use the `DIRECT|COMPRESS_OFFLOAD` port that the plain XML already declares, via
   players that request direct PCM output.

Neither restores Sony's parameter plumbing (DSEE on/off, EQ, gain mode). That
needs a small app calling `AudioManager.setParameters("izm_...")`, if the HAL
accepts the keys without Sony's AudioFlinger filter.

Android 14's bit-perfect mixer mode (`AUDIO_OUTPUT_FLAG_BIT_PERFECT`) is
documented as optional and as supported only by the **AIDL** audio HAL
(source.android.com/docs/core/audio/preferred-mixer-attr). Sony's HAL is HIDL 4.0,
so that path is open only to route B.

## 3. AVB and unlock

Locked, verified, and unlockable by design. The bootloader is NXP's U-Boot with
the standard NXP fastboot lock flow.

| Evidence | Source |
|---|---|
| `ro.frp.pst=/dev/block/by-name/presistdata` (the persistent data block behind the Developer options "OEM unlocking" switch) | `vendor.img:/build.prop` line 41 |
| `ro.hardware.bootctrl=avb` | `vendor.img:/build.prop` line 25 |
| vbmeta: `SHA256_RSA4096`, `Flags: 0`, rollback index 0, hash descriptors for `boot` and `dtbo`, hashtree for `system` and `vendor` | `avbtool info_image --image vbmeta.img` |
| `flashing unlock.`, `flashing lock.`, `get_unlock_ability`, `It is able to unlock device. %d`, `It is not able to unlock device.`, `unlock_critical`, `fastboot lock status: locked.` | `strings bootloader.img` |
| `androidboot.verifiedbootstate=orange androidboot.flash.locked=0 androidboot.slot_suffix=%s %s`: an unlocked boot path exists | `strings bootloader.img` |
| `Detect USB boot. Will enter fastboot mode!`, `is_fastboot_key_pressing`, `recovery: [VOL-]` | `strings bootloader.img` |
| vbmeta public key checked against RPMB: `fsl_validate_vbmeta_public_key_rpmb` | `strings bootloader.img` |
| live unit: `ro.boot.flash.locked=1`, `ro.boot.verifiedbootstate=green`, `sys.oem_unlock_allowed=0` | device capture 2026-09-24 |

Reading, from NXP's published U-Boot design rather than traced in this binary:
the Developer options switch writes the unlock-ability bit into `presistdata`,
and `fastboot flashing unlock` refuses unless it is set. This supports the
Head-Fi A100 report ("unlock toggle in developer options, USB fastboot"). The
older XDA "not accessible" report is not supported by anything in the firmware.
Not settled from files: the exact key combination into fastboot, and whether
`fastboot oem unlock` (the wording in the 2026-09-24 devlog, which came from
community notes) exists as an alias. The bootloader only shows `flashing unlock`.

## 4. RAM

**4 GB, from the device. The firmware does not show it.**

- Retracted: the device tree says 2 GiB. Every `dtbo.img` entry (6, `model=ICX1295`,
  `compatible=fsl,imx8mm-evk`) has `/memory@40000000 reg = <0 0x40000000 0
  0x80000000>`, i.e. 2 GiB. That is the i.MX 8M Mini EVK default left in place;
  U-Boot rewrites the node at boot.
- The live unit reports `MemTotal: 3979544 kB` (3.80 GiB), above anything a 2 GiB
  part could show, and 210 MiB short of 4 GiB, which is the reserved carve-outs
  (`device-capture/20260924T140409Z/meminfo.txt`).
- Boot command line reserves `cma=800M@0x400M-0xb7fM` for display/VPU buffers
  (`docs/static-analysis.md` §2).

4 GB is enough for Android 13 and later on route A. For comparison, the
`dalvik.vm.heapgrowthlimit=192m`/`heapsize=512m` values in the vendor are
phone-class values.

## The A105 (NW-A100 series)

- Sony's CDN carries 14 A100 packages: series `0000`-`0006` at 4.05.00/4.06.00,
  plus China 4.04.00/4.08.00 in series `0003`. Same contents-index numbering and
  same publish dates as the ZX500 set. `NW-A100_0000_V4_06_00` (906,889,168 bytes,
  SHA-256 `7a1bbe7b...`) is archived and listed in `firmware/MANIFEST.tsv`.
- **Refuted: one key for both.** The ZX507's `_KAS_` does not decrypt it
  (`error: SHA-224 mismatch: header=18e7d956... computed=378e5e6a...`). The key is
  per model, and the A100 key sits in the A100's own
  `/vendor/usr/data/icx_nvp.cfg`.
- Indirect twin evidence that needs no key: the ZX507 vendor already carries the
  A100 board's DSEE AI tables (`DseeAi_ICX1293.*`), and `diag_main` plus the USB HAL
  reference `icx1293`. The two boards are built from one vendor tree.
- **No A105 unit is available** (operator, 2026-10-14). The A105 stays inferred
  from the twin evidence above. Anything built here should be described as
  "tested on ZX507; A105 untested". An A105 owner can unblock the static analysis
  with one read-only `adb shell cat /vendor/usr/data/icx_nvp.cfg`.

## What stage 2 would be (needs the operator's approval)

ZX507 only, written out step by step in `stage2-gsi-runbook.md` with gates and
rollback. In short:

1. Developer options → OEM unlocking, then `fastboot flashing unlock`. **This
   wipes `userdata`.**
2. Verity-disabled vbmeta, then flash the TrebleDroid Android 13 arm64 GSI
   (1,931,804,672 bytes, fits) to `system_b`; this unit boots slot **b**.
3. Measure: boot, Wi-Fi/BT, sound through the Sony HAL, the output sample rate
   AudioFlinger opens (`dumpsys media.audio_flinger`), then swap in the high-res
   policy XML and measure again.
4. Only if 3 is promising: decide between polishing route A and starting route B.

Licensing: no Sony binary, image, key or decrypted package leaves this machine.
Only scripts, patches, measurements and method notes are publishable.
