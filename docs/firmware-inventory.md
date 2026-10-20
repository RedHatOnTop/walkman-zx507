# NW-ZX500-series firmware inventory

Recorded 2026-09-24. Source: Sony's own update CDN, `info.update.sony.net`.
Files were probed with HTTP `HEAD`; sizes below are the CDN's `Content-Length`
and dates are `Last-Modified`.

## How these URLs were found

Two independent routes, because Sony does not publish a plain file list:

1. **China service site.** Firmware detail pages are Vue apps that fetch their
   download links from
   `/casch/outDownload?method=findOne&path=/etc/commerce/products/casch/pim/download/firmware/<id>`.
   Older records still carry a populated `downloadPath`, which is where the
   `info.update.sony.net` URL pattern came from. The 4.04.00 record
   (`00002876`) and the 4.08.00 record (`00002909`, whose `downloadPath` is now
   empty because it ships over Wi-Fi / Music Center) were both checked.
2. **Pattern probing.** The filename is deterministic --
   `NW-ZX500_<series>_V<version>_NW_WM_FW.UPG` -- so the contents index was
   swept with `HEAD` requests across series `0001`-`0006`, contents `0001`-`0070`,
   and versions `V4_02_00` through `V4_08_00`. Only the files listed below
   returned HTTP 200; no `V4_02/03/05/07` build and no international 4.08.00
   build exists on the CDN.

Working probe (bash):

```bash
probe() { r=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 -I "$1"); \
          [ "$r" = 200 ] && echo "HIT $1"; }
export -f probe
for n in $(seq -w 1 70); do
  echo "https://info.update.sony.net/PA001/NW-ZX500Series_0003/contents/00$n/NW-ZX500_0003_V4_08_00_NW_WM_FW.UPG"
done | xargs -P 12 -I{} bash -c 'probe "{}"'
```

## Inventory

| Label | Series | URL path | Size (bytes) | Last-Modified |
|---|---|---|---|---|
| `zx500_chn_4.04.00` | `NW-ZX500Series_0003` | `/contents/0013/NW-ZX500_0003_V4_04_00_NW_WM_FW.UPG` | 486,161,168 | 2026-03-23 04:05:09 UTC |
| `zx500_chn_4.08.00` | `NW-ZX500Series_0003` | `/contents/0014/NW-ZX500_0003_V4_08_00_NW_WM_FW.UPG` | 486,061,952 | 2026-03-23 04:05:14 UTC |
| `zx500_intl_4.06.00_s0` | `NW-ZX500Series_0000` | `/contents/0015/NW-ZX500_0000_V4_06_00_NW_WM_FW.UPG` | 907,457,808 | 2021-11-30 04:12:42 UTC |
| `zx500_intl_4.06.00_s1` | `NW-ZX500Series_0001` | `/contents/0016/NW-ZX500_0001_V4_06_00_NW_WM_FW.UPG` | 910,338,016 | 2021-11-30 04:13:34 UTC |
| `zx500_intl_4.06.00_s2` | `NW-ZX500Series_0002` | `/contents/0015/NW-ZX500_0002_V4_06_00_NW_WM_FW.UPG` | 907,411,888 | 2021-11-30 04:14:14 UTC |
| `zx500_intl_4.06.00_s4` | `NW-ZX500Series_0004` | `/contents/0015/NW-ZX500_0004_V4_06_00_NW_WM_FW.UPG` | 907,426,160 | 2021-11-30 04:14:57 UTC |
| `zx500_intl_4.06.00_s5` | `NW-ZX500Series_0005` | `/contents/0015/NW-ZX500_0005_V4_06_00_NW_WM_FW.UPG` | 907,414,432 | 2021-11-30 04:15:47 UTC |

Base URL for all rows: `https://info.update.sony.net/PA001`. Full URLs are in
`firmware/MANIFEST.tsv` after running the fetch script.

## Observations

- The China builds are ~486 MB; the international 4.06.00 builds are ~907-910 MB.
  The ~420 MB difference matches the community claim that the China firmware
  ships without Google services and leaves more internal storage free.
- **Series `0000` exists and was missed by the first census**, which probed
  `0001`-`0006`. It is the only 4.06.00 build whose `post-build` matches the
  captured unit (`icx1295_002`, build 316), so it is the exact restoration
  source for this player. Seven files are now archived, not six.
- Each series id publishes its own 4.06.00 build, i.e. one file per
  destination/region variant. They are not byte-identical, so a complete archive
  keeps all five.
- Sony rewrote the two China files on 2026-03-23, the same day the 4.08.00 China
  release was announced. The CDN is live but is re-published in place, which is a
  reason to hold local copies rather than URLs alone.
- The 4.04.00 China build is the one the community kernel work targets
  (`ZX500-USB-DAC` is built and tested against 4.04.00 CHN), so it remains the
  most important single file for the kernel path.

## Verification

State of the local archive (2026-09-24):

- Seven `.UPG` files are held locally and their sizes match the live
  `Content-Length` byte for byte: the six from the first fetch
  (4,605,854,016 bytes, ~4.29 GiB) plus series `0000` (907,457,808 bytes).
- `firmware/MANIFEST.tsv` records per file: `size_bytes`, `last_modified`,
  `sha256` of the whole file, `embedded_hex` (the 56-character field at bytes
  4..59), and `payload_sha224` (SHA-224 from byte 129 onward).
- **The embedded field is the SHA-224 of the decrypted payload**, confirmed from
  the updater's own check and then verified against decrypted output
  (`sha224sum` of the zip equals the field, for series 0000 and 0002).
- `embedded_reproducible=no` in the manifest is therefore expected: the
  comparison there is against ciphertext, not plaintext, and the manifest
  predates the `0000` addition. Use `scripts/decrypt-upg.sh`, which performs the
  plaintext digest check itself, for content verification.

Re-verify an archive in place (recomputes sizes and hashes, writes nothing):

```bash
scripts/fetch-firmware.sh --verify
```

Follow-up experiment once a key is captured: check whether `embedded_hex` equals
SHA-224 of the decrypted OTA zip, and whether `payload_sha224` or the file
SHA-256 appears anywhere in Sony's update metadata. Either result turns the
field into a usable end-to-end integrity check.

## Container structure (decoded from `NW-ZX500_0002_V4_06_00`, 907,411,888 bytes)

| Offset | Bytes | Content |
|---|---|---|
| 0 | 4 | ASCII `NWWM` |
| 4 | 56 | ASCII hex = SHA-224 of the **decrypted** payload (confirmed from the updater) |
| 60 | 32 | 32 ASCII `0` characters |
| 92 | 12 | ASCII decimal `000907411755` -- the **plaintext size** |
| 104 | 24 | zero bytes |
| 128 | rest | encrypted payload, 907,411,760 bytes |

`907411760 - 907411755 = 5`. Five bytes is exactly a valid PKCS#5 pad for a
16-byte block cipher, which is strong evidence the payload is a padded block
cipher stream with the plaintext length recorded in the header. The payload is
definitely encrypted: no `PK\x03\x04`, `PK\x05\x06`, `CrAU`, `ANDROID!`,
`payload.bin` or gzip magic appears in the first 2 MiB or the last 64 KiB.

## Decryption scheme: SOLVED (from Sony's own updater)

Recovered by decompiling the on-device updater,
`com.sony.walkman.systemupdater` (`/system/priv-app/automagic/automagic.apk`,
997 KB dex, no native code), with apktool. Relevant classes:
`util/UpdateDataDecipher`, `util/UpdateDataDecipher$UpdateMetaStore`,
`util/UpdateProperties`, `com/sony/walkman/izmproperties/IzmProperties`.

```
read exactly 0x80 = 128 header bytes
  [0:4]     must equal "NWWM"      (wrong value -> "Magic error. can not update.")
  [4:60]    56 ASCII hex -> 28 bytes = SHA-224 of the DECRYPTED payload
  [60:92]   32 ASCII '0'   (ignored by the app)
  [92:104]  12-digit ASCII decrypted size (ignored by the app)
  [104:128] zero bytes
key = IZM property "ro.updater.info" bytes[0x00:0x20]     (AES-256)
iv  = same property            bytes[0x20:0x30]
cipher = AES/CBC/PKCS5Padding, DECRYPT_MODE
input position = 0x80 (128), streamed in 0x27100-byte buffers
output = /data/ota_package/NW_WM_FW.zip   -> payload.bin + payload_properties.txt
verify = SHA-224 over the whole decrypted output must equal header[4:60],
         else "Checksum does not match!"
then   = update_engine_client applyPayload(...) with the extracted properties
```

Exact smali evidence: `UpdateDataDecipher.decipher()` reads `0x80` bytes and calls
`FileChannel.position(0x80)`; `UpdateMetaStore` copies header bytes 0..3 into
`mSc` (compared against `:array-data 0x4E 0x57 0x57 0x4D` = `NWWM`) and
`0x38` = 56 bytes at offset 4 into `mSumRaw`, hex-decoded into `mSum`;
`UpdateProperties` does
`keyBytes = IzmProperties.get("ro.updater.info"); mKey = copyOfRange(keyBytes, 0, 0x20);
mIv = copyOfRange(keyBytes, 0x20, 0x30)`.

Consequences:

- The header digest is over the **plaintext**, which confirms the earlier
  hypothesis and turns `embedded_hex` into a real end-to-end integrity check the
  moment decryption works.
- The two hardcoded strings in the dex (`test_for_aes256bit_decode_perfom`,
  `test_iv_stringzz`) are dead debug defaults stored in `tmpKey256`/`tmpIv`;
  `getKey()`/`getIv()` return `mKey`/`mIv`, which come from IZM. Tested against
  the payload: no decrypt.
- The `_KAS_` field in `/vendor/usr/data/icx_nvp.cfg` (48 chars, commented
  `#@ Key`) **is** the key material, verified: `_KAS_[0:32]`/`_KAS_[32:48]`
  decrypt the payload and reproduce the header digest. The updater obtains the
  same 48 bytes through the IZM HAL (`ro.updater.info`), which is why the value
  also exists on disk in the NVP config. Earlier notes claiming it did not work
  were wrong; see "Lesson" below.

## Verified decryption recipe

The key **is** on disk: it is the `_KAS_` field of the device's own
`/vendor/usr/data/icx_nvp.cfg` (section commented `#@ Key`), a quoted
48-character string. Earlier notes here claimed otherwise; that was wrong, and
`scripts/decrypt-upg.sh` now implements and self-checks the recipe.

```bash
adb shell cat /vendor/usr/data/icx_nvp.cfg > secrets/icx_nvp.cfg
scripts/decrypt-upg.sh firmware/NW-ZX500_0000_V4_06_00_NW_WM_FW.UPG -o out.zip
```

The script decrypts with `-nopad`, truncates to the declared size, and refuses to
write the output unless SHA-224 of that truncation equals the header digest.
Confirmed on four packages (series 0000, 0001, and both China builds): digest
matched and `unzip -t` passed on every one.

| Field | Value |
|---|---|
| key | `_KAS_[0:32]` |
| iv | `_KAS_[32:48]` |
| cipher | AES-256-CBC, no padding |
| ciphertext | byte 128 to EOF |
| plaintext | first N bytes of the decrypted stream |
| N | 12 ASCII digits at offset 96 |
| check | SHA-224(plaintext) == 56 hex chars at offset 4 |
| discard | ciphertext length minus N (observed 5, 6, 9, 10 and 16 bytes) |

The trailing discard is what broke the early attempts: it is **not** valid
PKCS#5 padding at the end of the ciphertext stream, so a padding oracle cannot
detect a correct key (see the lesson below).

## What was extracted

The parallel session's output under `extracted/codex-20260924T1406Z/` was
re-verified here from the project root:

- `sha256sum -c PRESERVATION-SHA256SUMS` -- 9/9 OK
- `sha224sum` of the decrypted zip == the `.UPG` header digest, for series 0000
  and 0002 independently
- `boot.img`: `ANDROID!` magic, `kernel_size = 28940800`, `page_size = 2048`
  (exactly the Sony boot-slot values the community kernel work hardcodes)
- `vbmeta.img`: `AVB0` magic, 4096 bytes
- `debugfs -R 'cat /system/build.prop' system.img` returns
  `SonyAudio/icx1295_002/icx1295:9/4.06.00/316:user/release-keys` -- this unit
- payload partitions: dtbo, boot, system, vendor, vbmeta, bootloader, m4_os

That closes the prerequisite gap: the stock `boot.img` needed to build a custom
kernel now exists locally and is hashed.

## What was NOT obtained

Device-specific writable partitions (`nvp`, `idd`, `rca`, `presistdata`) are not
in the OTA payload and a direct block read is denied to shell, so a full
per-unit eMMC backup is still impossible without root. The OTA images are the
official target images, not a dump of this unit's flash.

## Lesson: two mistakes cost a day

1. **The CDN census missed series `0000`.** Only series `0001`-`0006` were
   probed, yet the unit's fingerprint (`icx1295_002`, build 316) matches only
   `NW-ZX500_0000_V4_06_00`. A sweep is only as complete as its index range, and
   the index started at 1 by assumption.
2. **A heuristic oracle was allowed to gate a definitive one.** The key was in
   the candidate set all along (file offset 1074, inside the 0..1188 window
   sweep), but the magic check only ran on candidates that first passed the
   PKCS#5 padding test -- and the padding test can never pass, because the
   stream's tail is discard bytes rather than a padded final block. Run the
   cheap definitive check (`PK\x03\x04`) on every candidate; use heuristics only
   to rank, never to filter.

## Prior failed attempts (kept for the record)

| Oracle | Rationale | Result |
|---|---|---|
| CBC first block = known magic at offset 128 | OTA zip starts with `PK\x03\x04` | not run on the correct candidate: it was gated behind the padding test |
| PKCS#5 padding valid on the final 16-byte block | assumed the tail was padded | 5 hits across 1,713 candidates, all false positives; the real key cannot satisfy it |
| Every quoted value / hex / base64 decoding as key||IV | covered the documented layouts | correct value missed by quote handling in one script, gated in the other |


## Community artifacts: what is and is not still obtainable

Checked 2026-09-24, because the porting path depends on them:

| Artifact | Status |
|---|---|
| Kernel source tree (`97lily/2019_android_walkman`, fork of `notcbw/2019_android_walkman`) | **Live.** Contains the Android kernel, `arch/arm64/boot/dts/sony/` board DTS tree, and the CXD3778GF codec driver. |
| `notcbw/2019_android_walkman` (original) | **Gone** -- repository returns 404. |
| `nwwmdecrypt.jar` (the community firmware decryptor) | **Unobtainable** at its documented release URL; the fork has no releases. Reimplemented here as `scripts/decrypt-upg.sh` from the documented scheme. |
| Prebuilt custom kernel `boot-zx500.img` | **Unobtainable.** The fork has no releases and the original is deleted. |
| [`remove/ZX500-USB-DAC`](https://github.com/remove/ZX500-USB-DAC) `release` branch | **Live.** Source, kernel patch, `kernel.config`, `SHA256SUMS`, `blank_vbmeta.img`, bridge binaries, scripts. |
| Prebuilt boot image in that repository | **Not distributed** -- `.gitignore` excludes `*.img` apart from `blank_vbmeta.img`. It must be built with `docker/zxbuild`. |
| Community unpacked fastboot firmware (Google Drive, linked from the fork README: 4.06 INTL, 4.04 CHN, A100 4.06 INTL) | **Not downloadable anonymously** -- `drive.google.com/uc?export=download` returns a 2,450-byte HTML interstitial for both file IDs tried, with and without `confirm=t`. |

Two consequences for the plan:

1. Building a custom kernel requires the **stock `boot.img`**, which is what this
   archive exists to provide. There is no downloadable substitute.
2. The decryptor is no longer a downloadable dependency. The scheme is
   documented (AES-CBC/PKCS5Padding, 32-character key + 16-character IV from
   `/vendor/usr/data/icx_nvp.cfg`), and `scripts/decrypt-upg.sh` implements it
   with openssl.
