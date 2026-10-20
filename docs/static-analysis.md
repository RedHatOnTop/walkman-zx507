# Static analysis of the stock 4.06.00 images

Everything here is derived from files already on disk; the device was not
touched. Sources: `extracted/codex-20260924T1406Z/exact-4.06.00-images/` plus
`scripts/parse-payload.py` for the OTA metadata.

## 1. Partition layout (authoritative, from the OTA manifest)

`scripts/parse-payload.py` reads the `DeltaArchiveManifest` out of
`payload.bin` inside the decrypted zip. The payload header is big-endian:
`CrAU` + u64 version + u64 manifest_size + u32 metadata_signature_size.
Partition size comes from `PartitionUpdate.new_partition_info` (protobuf field
7; field 6 is the *old* info and is empty in a full OTA).

| Partition | Size (bytes) | Exact | SHA-256 (first 16) |
|---|---:|---|---|
| system | 3,145,728,000 | 3000 MiB | `2a3db28862e38e60` |
| vendor | 209,715,200 | 200 MiB | `be305cf1e263c162` |
| boot | 50,331,648 | 48 MiB | `922d1e878ca6fd7f` |
| bootloader | 6,963,200 | 6.64 MiB | `99e261d6dc0b11d3` |
| dtbo | 4,194,304 | 4 MiB | `daf251225f8fedb7` |
| m4_os | 40,960 | 40 KiB | `c32a2165afdf3fc8` |
| vbmeta | 4,096 | 4 KiB | `3669ca5c0dc2aa28` |
| **total** | **3,416,977,408** | 3258.68 MiB | |

This answers the GSI sizing question that `/proc/partitions` could not (it is
denied to shell): **the system partition is exactly 3000 MiB**, so a GSI must be
at most 3,145,728,000 bytes. Android 9/10 arm64 A/B GSIs are typically
1.5-2.5 GB, so there is room. Feasibility is now size-constrained only by the
GSI's own image size, not by an unknown partition.

The `system.img` extracted by payload-dumper-go is exactly the partition size
(3,145,728,000), i.e. payload images are partition-sized, not blob-sized.

## 2. `boot.img` anatomy

Parsed header (Android boot image, header_version 1, page size 2048):

| Field | Value |
|---|---|
| magic | `ANDROID!` |
| kernel_size | **28,940,800** bytes |
| kernel_addr | `0x40480000` |
| ramdisk_size | 12,622,703 bytes |
| ramdisk_addr | `0x43600000` |
| second_size | 0 |
| tags_addr | `0x40400100` |
| os_version | `301990235` |
| id (SHA-1) | `820ccfad0ab0deaea8529ba2fe740e257610c32f` |

Physical layout inside the 48 MiB partition:

| Range | Content |
|---|---|
| 0 .. 2,048 | boot header (1632 bytes, page-padded) |
| 2,048 .. 28,942,848 | kernel, 28,940,800 bytes |
| 28,944,384 .. 41,567,087 | ramdisk, 12,622,703 bytes |
| 41,568,256 | `original_image_size` per the AVB footer |
| 41,570,304 .. 41,570,816 | vbmeta struct, 512 bytes |
| 50,331,584 .. 50,331,648 | AVB footer (`AVBf`, version 1) |

The AVB footer is `magic[4] + version_major u32 + version_minor u32 +
original_image_size u64 + vbmeta_offset u64 + vbmeta_size u64 + reserved`,
all big-endian. This is the exact structure any repacking tool must preserve:
the community `kernel/pack-boot.py` writes a new kernel into the stock image and
therefore depends on this layout being intact.

**Kernel slot limit confirmed independently.** The stock header records
`kernel_size = 28,940,800`, matching the constant the community build script
asserts against (`LIMIT=28940800`). The stock kernel Image is an arm64 image
with an EFI stub (`MZ` at offset 0, `ARMd` magic at 0x38) and fills
28,940,296 bytes of the slot. This is why the community build pins GCC 4.9:
a modern toolchain produces roughly 32 MB, which does not fit.

Command line (from the boot header):

```
init=/init androidboot.console=ttymxc1 androidboot.hardware=icx1295
cma=800M@0x400M-0xb7fM androidboot.primary_display=imx-drm
firmware_class.path=/vendor/firmware transparent_hugepage=never
androidboot.displaymode=720p buildvariant=user
```

## 3. The ramdisk is the recovery ramdisk

224 entries. Notable contents:

| Path | Note |
|---|---|
| `init` | 2,079,256 bytes |
| `init.rc`, `init.recovery.icx1295.rc`, `init.recovery.icx1295.emmc.rc`, `init.recovery.icx1295.sd.rc` | recovery init scripts |
| `etc/recovery.fstab` | system mounted as `/` with `wait,slotselect` |
| `sbin/recovery` | recovery binary present |
| `sbin/update_engine_sideload`, `sbin/adbd`, `sbin/e2fsdroid_static`, `sbin/mke2fs_static` | recovery tools |
| `etc/update_engine/update-payload-key.pub.pem` | **OTA payload signing key (2048-bit RSA)** |

This is consistent with the known shape of the device: system-as-root with no
separate recovery partition, so `boot.img`'s ramdisk *is* recovery. It is also
the concrete reason Magisk's normal boot-image patching cannot work here, and why
the community concluded (correctly) that KernelSU is the only root path.

The payload signing key is a public key, safe to record; its DER SHA-256 is
`77ae43875b4e7ba767e713e3d55d849e14eece92283e8d1897a965586be38f6a`. It means
`update_engine` will only accept payloads signed by Sony's private key.

`init.recovery.icx1295.rc` also shows the recovery USB gadget: idVendor
`0x18d1`, idProduct `0x4ee7`, function `ffs.adb`, and a `tool_switcher` service.

## 4. Kernel configuration (extracted from the kernel image)

`CONFIG_IKCONFIG=y`, so the kernel embeds its own config: `IKCFG_ST` at offset
15,356,104, gzip stream, `IKCFG_ED` at 15,394,154. 6,487 lines,
168,642 bytes. Extracted to `/tmp/kconfig.txt` (not committed; see the licensing
note in the README).

Findings that change project decisions:

| Option | Value | Why it matters |
|---|---|---|
| `CONFIG_INITRAMFS_FORCE` | **absent from the config** | Answers the never-resolved question in Magisk issue #7337 ("Is `CONFIG_INITRAMFS_FORCE` set in the kernel?"). It is not set, and not present at all; the only initramfs options are `CONFIG_BLK_DEV_INITRD=y` and `CONFIG_INITRAMFS_SOURCE=""`. The kernel does **not** force a built-in ramdisk, so Magisk's failure here is not explained by this option. |
| `CONFIG_USB_CONFIGFS_F_UAC2` | **not set** | The stock kernel cannot present a UAC2 USB-DAC gadget. `ZX500-USB-DAC` therefore requires a kernel rebuild, not just a runtime patch. Also `F_UAC1`/`F_UAC1_LEGACY` are off. |
| `CONFIG_USB_CONFIGFS_F_FS`, `F_MTP`, `F_AUDIO_SRC`, `F_HID`, `F_MIDI` | `y` | adb/MTP and friends are available; only the audio-class gadget is missing. |
| `CONFIG_MODULES` | `y` | Loadable modules are supported. |
| `CONFIG_MODULE_SIG` | **not set** | Unsigned modules can be loaded, so the kernel-module route (as used by the Walkman tone-table work) is viable without signing keys. |
| `CONFIG_SECURITY_SELINUX_DEVELOP` | `y` | SELinux can be switched to permissive, matching the ZX500-USB-DAC note that its reference device ran permissive. |
| `CONFIG_SND_SOC_CXD3778GF` | `y` | Sony's audio codec driver is built **into** the kernel, alongside `CONFIG_SND_SOC_IMX_CXD3778GF=y`. |
| `CONFIG_DM_VERITY` | `y` | dm-verity is on; vendor is mounted from `/dev/block/dm-1`, as seen on the running device. |
| `CONFIG_KALLSYMS` | `y` | Symbols available for reverse engineering. |
| `CONFIG_SECURITY_SELINUX` | `y` | Enforcing on the live device. |

## 5. Modules and codec libraries in `vendor`

`/vendor/lib/modules/` (from `debugfs` on `vendor.img`):

| Module | Size | Note |
|---|---|---|
| `wlan.ko` | 7,484,288 | WiFi driver, by far the largest |
| `icx_nvp_emmc.ko` | 83,536 | NVP access; `start_initialize` insmods this before writing NVP |
| `cxd3778gf_dnc_core.ko` | 33,200 | codec companion module (DNC) |
| `modules.dep`, `modules.alias` | 145 / 1,545 | dependency metadata |

`/vendor/lib/` holds NXP/Sony multimedia decoders, i.e. the Hi-Res audio path
lives in userspace blobs, not only in the kernel driver:
`lib_flac_dec_v2_arm11_elinux.so`, `lib_mp3_dec_v2_arm12_elinux.so`,
`lib_aacplusd_wrap_arm12_elinux_android.so`, `lib_wb_amr_dec_arm9_elinux.so`,
`lib_omx_mp3_dec_v2_arm11_elinux.so`, `lib_omx_common_v2_arm11_elinux.so`,
`libdrm_vivante.so`, `libtrusty.so`.

## 6. Sony DAP components in `system`

`/system/priv-app/` includes the DAP-specific set:
`HighResMediaPlayerApp`, `IzmAudioManager`, `IzmDeviceManager`,
`AudioInfoExtractor`, `MusicFX`. Together with the board audio HAL
(`/vendor/lib64/hw/audio.primary.icx1295.so`, 2.7 MB) these are the pieces a
porting effort would have to keep or replace; see `device-report.md` for the full
HAL inventory.

## 7. Region comparison (CHN vs international)

Same partition table in every region -- 3000 MiB system, 200 MiB vendor,
48 MiB boot -- differing only in content. Compressed blob sizes per partition:

| Partition | 4.04.00 CHN | 4.06.00 INTL (`0000`) | delta |
|---|---:|---:|---:|
| system | 429,421,748 | 852,404,290 | **+422,982,542** |
| vendor | 34,985,379 | 33,298,224 | -1,687,155 |
| boot | 20,946,882 | 20,947,106 | +224 |
| bootloader | 665,912 | 665,896 | -16 |
| dtbo | 13,657 | 13,664 | +7 |
| m4_os | 23,512 | 23,512 | 0 |
| vbmeta | 2,280 | 2,276 | -4 |

The entire regional difference is the system partition: the international build
carries **~423 MB more compressed content**, which is the Google Mobile Services
payload. Vendor and boot are effectively identical (the Chinese vendor image is
marginally *larger*). This turns the community's "China firmware has no Google
services and better battery life" claim into a measurement, and it confirms that
cross-flashing regions does not require a different partition layout.

## 8. Verified chain of custody

Each step was checked against an independent value rather than assumed:

| Check | Result |
|---|---|
| `.UPG` decryption | SHA-224 of the decrypted zip equals the header digest, 4 packages |
| Payload extraction | extracted `boot` SHA-256 equals the manifest's declared partition hash |
| Manifest sanity | payload version 2, manifest 91,989 bytes, 264-byte signature -- matches the original dumper's log |
| Region identity | CHN `system` blob is 423 MB smaller than INTL, consistent with GMS absence |

The strongest result: the 4.04.00 CHN `boot` partition extracted here hashes to

```
e2e398948de76977549d922f8c0891969a3277813e83c75462bbf184c24a193a
```

which is exactly the value `ZX500-USB-DAC`'s README documents for the stock
`boot.img` it requires (and which it tells users to obtain from a Google Drive
mirror that no longer responds). So the required input for the custom-kernel
build is now identified, verified by hash, and held locally:

```
extracted/stock-boot-images/boot-4.04.00-chn.img    e2e39894...
extracted/stock-boot-images/boot-4.06.00-0000-intl.img  922d1e87...  (this unit's build)
```

Install operations in these packages are `REPLACE_XZ` and `REPLACE_BZ`, so
`scripts/extract-partition.py` handles both (it is a standard-library
replacement for the missing `payload-dumper-go`, and refuses delta op types).

## 9. What this changes

1. **GSI sizing is no longer unknown**: 3000 MiB system. Keep the target GSI
   under 3,145,728,000 bytes.
2. **The custom-kernel constraint is quantified**: 28,940,800 bytes of kernel,
   48 MiB partition, so repacking must preserve the AVB layout (image, then
   512-byte vbmeta struct at 41,570,304, then the footer at 50,331,584).
3. **The kernel build's stock input is secured**: 4.04.00 CHN `boot.img`,
   hash-verified.
4. **USB-DAC needs a kernel build**: `F_UAC2` is off in stock.
5. **Kernel modules are a viable, unsigned route**: `MODULE_SIG` is off.
6. **The Magisk question is closed**: `INITRAMFS_FORCE` is not set.
7. **Payload signing is real**: update_engine verifies against Sony's RSA key,
   so modified OTAs cannot be sideloaded through the normal updater.
8. **Region differences are content-only**: no partition-layout difference, so
   the CHN build is the lighter choice and the INTL build is a drop-in swap.