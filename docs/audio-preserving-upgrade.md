# Keeping Sony's audio stack on a newer Android

Recorded 2026-10-14, static analysis only (no device). The question: how far can
the ZX507 move past Android 9 without losing what makes it a Walkman, meaning
Sony's DSP, the direct hi-res path, DSD, and the low-power playback mode.

Inputs: the stock 4.06.00 images (`extracted/codex-20260924T1406Z/`), the
TrebleDroid Android 13 GSI in `gsi/` (`ci-20230905`, android_13.0.0_r73), and
two tools written for this pass: `scripts/disasm.py` (AArch64 disassembly with
PLT and string resolution, capstone 5.0.6) and `scripts/abi-check.py` (resolves
a library's imports against another system's libraries).

## Answer

Up to **Android 13**, with the whole kernel and vendor left untouched, plus a
thin system-side layer rebuilt by us. Sony's sound lives almost entirely below
the framework. What sits above it is small, has been mapped, and can be
re-created:

| Piece | Where | Survives a GSI as-is? | What it takes |
|---|---|---|---|
| CXD3778GF codec driver (S-Master HX) | kernel | yes (stock kernel kept) | nothing |
| DSP: DSEE AI, DC Phase Linearizer, Vinyl, EQ10, tone, SRC, DSD filters | vendor HAL `audio.primary.icx1295.so` | yes | nothing |
| Audio HAL transport (HIDL 4.0) | vendor | yes: the A13 GSI ships `libaudiohal@4.0.so` | nothing |
| Hi-res policy XML, 44.1-192 kHz primary, DIRECT/OFFLOAD port to 384 kHz + DSD | vendor `etc/` | file yes, selection no | framework patch (WP1) |
| LPA (AP sleeps while the HAL plays a 20 s buffer) | system `libaudioflinger.so` | **no** | framework patch (WP1) |
| `izm_*` key handling and the uid firewall | system `libaudioflinger.so` | **no** | framework patch (WP1) |
| `IzmAudioManager`, `IzmDeviceManager`, `AudioInfoExtractor` | system priv-app, `sharedUserId=android.uid.system` | **no**: signature | local re-sign (WP2) |
| `HighResMediaPlayerApp` + `libspmedia_walkman.so` | system priv-app + JNI | **no**: ABI | AudioTrack proxy shim (WP2) |

Android 14 and later stay out of reach on this route for the reasons in
`android-upgrade-feasibility.md`: no VNDK 28, no FCM level 3, no 4.14 kernel
configs. The pieces mapped here carry over to a full rebuild (route B) later.

## How Sony's playback path works (from the binaries)

1. **Player:** `HighResMediaPlayerApp` (`com.sony.walkman.highresmediaplayer`,
   target SDK 28) decodes in its own native engine (`libwmmediaplayer_walkman.so`,
   `libspmedia_walkman.so`; DSD, DSD→PCM and fades all happen there) and writes
   through a native `android::AudioTrack`.
2. **Output flags**, read from `NativeAudioTrackSinkFilter::setup()` at `0x5bcf8`:
   - PCM: format 1 (16-bit) or 3 (32-bit) at the source's own sample rate, with
     `flags = 0x1` (`AUDIO_OUTPUT_FLAG_DIRECT`). The code is
     `csinc w9, w9(0x10), wzr, ne` on `format >> 24`.
   - DSD: format `0x1A000000` (`AUDIO_FORMAT_DSD`) with `flags = 0x10`
     (`COMPRESS_OFFLOAD`) and a filled `audio_offload_info_t`.
   - Attributes: usage 1 (media), content 2 (music).

   All of these are AOSP values, and the vendor policy already declares a
   `DIRECT|COMPRESS_OFFLOAD` port with PCM 16/32-bit up to 384 kHz and DSD64-256.
   So the bit-perfect path is the **direct output**, not a patched mixer.
   **Seen live (2026-10-14 19:02, `device-capture/20261014T100227Z-playback/`).**
   While W.music played a track over wired headphones:
   - AudioFlinger had opened `AudioOut_2D`, **type 4 (OFFLOAD)**, not standby,
     44100 Hz `PCM_16_BIT`, device `WIRED_HEADPHONE`. Its HAL stream flags were
     `0x11 (DIRECT|COMPRESS_OFFLOAD)`.
   - The one active track sat at 44100 Hz, format 1, with **0 dB** L/R and
     volume-shaper gain, and the thread had no effect chains. So there is no
     resampling, software gain or framework effect on the way to Sony's HAL.
   - The 192 kHz mixer threads were idle (`Standby: yes`).

   The player asks for `DIRECT` only. The thread is an offload thread because
   the matched port also carries `COMPRESS_OFFLOAD`, which is how AOSP opens a
   profile's own flags (to be confirmed on A13). A 96 kHz file two minutes later
   (`device-capture/20261014T100408Z-playback-96k/`) opened a fresh offload
   output at **96000 Hz `PCM_32_BIT`**, again with 0 dB track gain. That matches
   the format mapping read from `NativeAudioTrackSinkFilter::setup()`, where
   24/32-bit sources go out as format 3.
3. **Before opening the track**, the player sets `vendor.audio.lpa.enable=1` and
   polls `AudioSystem::getParameters("izm_stream_opened")` until it reads 0.
4. **Control:** the player binds `IzmAudioManager` over AIDL (`IIzmAudioManager`,
   about 66 methods). That service only uses the public
   `AudioManager.setParameters`/`getParameters` with `izm_*` keys: volume, EQ,
   DSEE AI, DC Phase Linearizer, Vinyl, NC/ambient, DSD filter and gain,
   S-Master gain mode, write/stop mode, and track extra info (codec, bit depth,
   MQA).

## What Sony changed in `libaudioflinger.so`

Located by string references in the disassembled `.text`. Function names are
stripped, so they come from `__func__` log arguments where possible.

| Change | Evidence | Behaviour |
|---|---|---|
| LPA wakelock bypass | `acquireWakeLock_l` checks `property_get_int32("vendor.audio.lpa.enable")` and logs `%s: disabled by vendor.audio.lpa.enable` (`0x413a4`) | no wakelock during LPA playback, so the AP can suspend while the HAL drains its buffer (`persist.vendor.lpa.buffer.time_ms=20000`) |
| Parameter firewall | `izmFilterVolumeParameters`, `izmFilterReservedParameters`, `%s: izm filtering key %s value %s from uid %d` (`0x27f40`..`0x28198`) | drops `izm_*` keys from callers that are not allowed; the Sony services run as system uid |
| Reserved-key state | `0x3cacc`: parses `izm_enable_nxp_lpa` (=="1"), `izm_source_direct` (=="on"), `izm_output_device` (!="none") into a global at `0xa0168`. `0x3cc78`: `izm_dsee_ai` (=="on") into `0xa01a8`, calling `0x3d0d8` when it changes | AudioFlinger-side state; when one of these keys is present the call returns without taking the generic path (`0x309e8`). What `0x3d0d8` does is not yet read |
| Mixer resolution | `0x3cdb0`: reads `persist.vendor.audio.mixerthread.res` and compares against `std` / `high` | selects 48k/16-bit vs hi-res mixer behaviour, paired with the policy side |
| Policy XML choice | `libaudiopolicymanagerdefault.so` holds `audio_policy_configuration_highres.xml`, `persist.vendor.audio.mixerthread.res`, `AudioPolicyManager::isPrimaryOutputHighResFormat` | loads the hi-res XML when asked to. Not traced in code, but the live unit (2026-10-14, `mixerthread.res=high`) reports the primary output at 44.1-192 kHz 16/32-bit, a profile only `_highres.xml` declares |
| Master volume | `izm_master_volume` referenced at `0x22068` | not yet read |

None of this needs Sony's code to be copied. Each item is a behaviour that can
be re-implemented as a patch on AOSP 13 `frameworks/av`, written from these
observations.

## Why Sony's player cannot just be copied onto Android 13

`scripts/abi-check.py` against the GSI's `/system/lib64` plus its runtime, ART
and i18n APEX libraries: **0 unresolved symbols** for all four Sony libraries.
A13's `libaudioclient.so` still exports the Android 9 overload of
`AudioTrack::set(..., unsigned int, int, audio_attributes_t const*, bool, float, int)`.
It links, and it would still crash:

- **Object size.** Sony allocates `operator new(0x3d8)` (984 bytes) before calling
  `AudioTrack::AudioTrack()`. A13's own callers allocate `0x4f0` (1264 bytes)
  (`libmedia_jni.so` `0x8a7bc`, `libaudioclient.so` `0xc1254`). The constructor
  would write 280 bytes past Sony's block.
- **RefBase layout.** Sony calls `RefBase::incStrong(track)` on the raw pointer:
  RefBase at offset 0 in Android 9. In A13, `RefBase` is a virtual base: callers
  load the offset from the vtable (`ldr x8,[x21]; ldur x8,[x8,#-0x18]; add x0,x21,x8`).

The surface to bridge is small. `libspmedia_walkman.so` imports, from Android
internals, only `android::AudioTrack` (8 symbols: constructor, `set`, `start`,
`pause`, `flush`, `write`, `latency`, static `getMinFrameCount`), `String8` (3),
`RefBase` inc/decStrong, `IMemory` (an empty `sp` argument),
`AudioSystem::getParameters`, and `sp_report_race`. `libspmedia_walkman_ex.so`
imports nothing from `android::`.

## Work packages

**WP1: framework patch set** (TrebleDroid A13 tree, `frameworks/av`). Re-implement
the LPA wakelock bypass, the `izm_*` firewall and reserved-key state, and the
`mixerthread.res`→hi-res XML selection. Building a GSI needs an AOSP checkout
(100+ GB) and a large machine. That means `aws-burst` (spot EC2) and **costs
money**, so it needs the operator's OK before it starts.

**WP2: running Sony's own apps**, installed by a script from the user's own
device or official `.UPG`. Nothing Sony-made is redistributed.

- Re-sign the three `android.uid.system` apps with the GSI's platform key.
  TrebleDroid builds are `test-keys`, and the GSI's `framework-res.apk` cert
  SHA-256 `C8:A2:E9:BC:CF:59:7C:2F:B6:DC:66:BE:E2:93:FC:13:F2:FC:47:EC:77:BC:6B:2B:0D:52:C1:1F:51:19:2A:B8`
  equals AOSP's public `platform.x509.pem`. The other side of the same fact:
  anyone can sign a system app for this GSI. That is acceptable for a personal
  player, not for a phone.
- Shim library `libspshim.so`. It exports the 8 `AudioTrack` symbols with a
  984-byte, RefBase-at-0 proxy object that owns a real A13 `AudioTrack`. Sony's
  `libspmedia_walkman.so` gets `DT_NEEDED libaudioclient.so` rewritten to it on
  the device, at install time.
- `privapp-permissions` allowlist XML for the priv-apps.

**WP3: open fallback**. A player of our own that opens a native `AudioTrack` with
`AUDIO_OUTPUT_FLAG_DIRECT` at the file's rate and drives the HAL with the same
`izm_*` keys. No Sony binaries at all; Sony's DSP still runs, because it is in
the vendor HAL. Use it if WP2 proves fragile, and as the publishable demo.

## Open, needs the device

- Whether stock A13 `AudioPolicyManager` routes a DIRECT PCM request to the
  `DIRECT|COMPRESS_OFFLOAD` port. Matching rules for `mustMatchOutputFlags`
  suggest yes; `audio.offload.disable=1` only gates offload.
- What `0x3d0d8` (DSEE AI change) and the `izm_master_volume` site do.
- Whether the HAL also needs the reserved keys that Sony's AudioFlinger swallows.
  The HAL's own strings include `izm_dsee_ai` and `izm_enable_nxp_lpa`.

Offline next steps, in order: read `0x3d0d8` and `0x22068`; write the shim
against A13 headers and the GSI's `libaudioclient.so`; draft the WP1 patches
against the android_13.0.0_r73 sources. Only the GSI build itself needs paid
compute.
