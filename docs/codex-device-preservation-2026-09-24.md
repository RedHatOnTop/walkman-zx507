# NW-ZX507 stock firmware preservation, 2026-09-24

This capture was read-only on the player. No unlock, root, remount, flash, or
reboot command was issued. The device remained on slot `_b` with verified boot
state `green` at the final check.

## Device match

The connected player's build fingerprint was
`SonyAudio/icx1295_002/icx1295:9/4.06.00/316:user/release-keys`. None of the
six previously archived `.UPG` files contained that `post-build` value. The
missing distribution series was `0000`, not `0001` through `0006`.

The exact matching official package is:

- Source: `https://info.update.sony.net/PA001/NW-ZX500Series_0000/contents/0015/NW-ZX500_0000_V4_06_00_NW_WM_FW.UPG`
- Local file: `firmware/NW-ZX500_0000_V4_06_00_NW_WM_FW.UPG`
- CDN `Content-Length`: 907,457,808 bytes; local size: 907,457,808 bytes
- CDN `Last-Modified`: Tue, 30 Nov 2021 04:12:42 GMT
- SHA-256: `1249a9baeda969b205d1db9fe335a133a131f4628d9d97e9120ea02a5be19dac`

The device's `/vendor/usr/data/icx_nvp.cfg` had already been captured at
`secrets/icx_nvp.cfg` with mode `0600`. Its contents were not printed or added
to this document. The exact package was decrypted locally into
`extracted/codex-20260924T1406Z/NW-ZX500_0000_V4_06_00_NW_WM_FW.zip`.
The decrypted ZIP is 907,457,664 bytes and has SHA-256
`0a7654e6f137661b2438e02f9d50885baed9448bb429e127282f2b3b3a711f34`.
The UPG's embedded SHA-224 matches the decrypted ZIP, every ZIP entry passed
CRC validation, and its `post-build` field matches the connected device.
The pre-existing `firmware/MANIFEST.tsv` has not yet been amended for series
`0000`; the checksum manifest below covers this package in the meantime. An
exploratory decrypted `0002` ZIP also remains in the same extraction directory,
but its metadata targets `icx1295_001` and it is not a restoration source for
this player.

## Extracted images

The full OTA payload was extracted with `ssut/payload-dumper-go` tag `1.3.0`
into `extracted/codex-20260924T1406Z/exact-4.06.00-images/`.

| Image | Size (bytes) |
|---|---:|
| `boot.img` | 50,331,648 |
| `bootloader.img` | 6,963,200 |
| `dtbo.img` | 4,194,304 |
| `m4_os.img` | 40,960 |
| `system.img` | 3,145,728,000 |
| `vbmeta.img` | 4,096 |
| `vendor.img` | 209,715,200 |

`extracted/codex-20260924T1406Z/PRESERVATION-SHA256SUMS` records the SHA-256
of the UPG, decrypted ZIP, and all seven images. Verification from the project
root:

```bash
sha256sum -c extracted/codex-20260924T1406Z/PRESERVATION-SHA256SUMS
unzip -t extracted/codex-20260924T1406Z/NW-ZX500_0000_V4_06_00_NW_WM_FW.zip
e2fsck -fn extracted/codex-20260924T1406Z/exact-4.06.00-images/system.img
e2fsck -fn extracted/codex-20260924T1406Z/exact-4.06.00-images/vendor.img
```

Observed result: nine SHA-256 checks reported `OK`; ZIP validation reported
`No errors detected in compressed data`; both filesystem checks exited zero.
The extracted system image's `/system/build.prop` contains the same build
fingerprint as the connected player.

## Limits and failed attempts

The images are the official OTA target images, not raw reads of the player's
eMMC. A direct read of `/dev/block/by-name/boot_b` failed verbatim with
`dd: /dev/block/by-name/boot_b: Permission denied`. A complete backup of
device-specific `nvp`, `idd`, `rca`, `presistdata`, and other writable partitions
therefore remains unavailable without higher privileges. The OTA payload does
not contain an `nvp` image. Do not treat these generic OTA images as a complete
per-unit backup.

An attempted ADB tar stream of the mounted `/system` and `/vendor` trees did
not pass archive validation: `tar: Skipping to next header` and
`tar: Exiting with failure status due to previous errors`. Those files are
marked `*.unverified.tar.zst` under
`device-capture/codex-20260924T1406Z/mounted/` and must not be used as
restoration sources. One subsequent `adb pull -a /vendor` reported
`/vendor/: 0 files pulled, 0 skipped.` The verified OTA images supersede these
incomplete live-file captures.

The previous general device inventory remains at
`device-capture/20260924T140409Z/`. No user music or private `/data` files were
copied. All proprietary images are for local recovery and research only; do
not redistribute them or the decryption key.
