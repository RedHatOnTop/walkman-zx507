# walkman-zx507

Android 13 for the Sony NW-ZX500 series (NW-ZX505, NW-ZX507), built on the owner's own machine
from TrebleDroid's public GSI and **the owner's own** Sony firmware. Sony's audio path stays:
W.music and Sony's sound settings run on Android 13 next to everything else a current Android
brings.

This repository ships no system image. It is a build kit. Sony's apps, libraries, boot
animation and ramdisk come out of the firmware file each owner downloads from Sony, are
patched on that owner's computer, and are never published here.

**Beta: not a stable release.** It is in daily use on one NW-ZX507, its author's, installed
clean from Walkman Manager, and has run on no other unit. Expect bugs and changes from one
version to the next; [`docs/install.md`](docs/install.md#known-issues) lists the known ones.
It comes with no warranty (sections 15 and 16 of the [GPL](LICENSE)).

## Install

The easiest way is **Walkman Manager** (`RedHatOnTop/walkman-manager`): its Firmware Studio
checks the files, reads the firmware key from the player, runs this kit and installs the
result over USB with an on-screen guide for every step the owner does by hand.

By hand: [`docs/install.md`](docs/install.md) has every step, what a build host needs, and the
known issues.

Either way:

- **Unlocking the bootloader wipes the player.** Back up internal storage first.
- Android 13 goes to slot **b**. Sony's firmware stays on slot a, untouched.
- Tested on an NW-ZX507 with firmware 4.06.00, series `0000`. Every step that patches a Sony
  file checks its hash first and stops on any other.

## What it does

| | |
|---|---|
| Kernel | Sony's 4.14 GPL source with four patches (`kernel/patches/`): the binder feature Android 13's keystore needs, a build fix for the SELinux host tools, the Himax touch firmware wait, exFAT for cards. Built with the stock release string, so Sony's vendor modules still load. |
| Audio | Sony's audio HAL and DSP stay on the vendor partition. W.music and its native libraries come from the firmware, on a shim that gives them the Android 9 `AudioTrack` they were built against (`audio-shim/`). |
| System | TrebleDroid ci-20230905 arm64 A/B vanilla, debloated, with Sony's apps, a black and champagne-gold theme, Quick Settings tiles, legacy Korean (CP949) file tags read correctly (`tag-charset/`), and microG. |
| Install | `scripts/make-install.sh`: one entry point from the owner's files to `system.img`, `boot.img`, `vbmeta.img` and an `install.json` that says what goes where and what to read back after boot. `scripts/make-restore.sh` makes the same kind of set from the four stock partitions, for going back to Sony's firmware. |

## Layout

| Path | Contents |
|---|---|
| `scripts/make-install.sh`, `make-restore.sh` | The kit's entry points, install and back to stock (Walkman Manager runs them). |
| `scripts/build-image.sh` | The system image, one step per script (`scripts/*-gsi.sh`). |
| `scripts/unpack-stock.sh`, `decrypt-upg.sh`, `extract-partition.py` | Sony's `.UPG`: decrypt, verify, extract. |
| `kernel/` | `build.sh` builds the kernel from Sony's GPL source, `release.sh` packs it with its source, `repack-boot.py` puts it into the stock boot image. |
| `audio-shim/`, `tag-charset/`, `compat-scale/`, `microg/`, `apps/` | Our own code that goes into the image. |
| `gsi-init/`, `gsi-overlays/`, `gsi-etc/`, `gsi-debug/` | Init scripts, resource overlays and the debug build's wrapper. |
| `kit/` | The hashes the kit checks its inputs against. |
| `docs/` | Install guide, feasibility notes, firmware inventory, static analysis. |
| `devlog/` | What was tried, what worked, what failed, by date. |

## Licensing

Our code and documentation are licensed under the **GNU General Public License v3.0 or
later** ([`LICENSE`](LICENSE)).

The kernel patches in `kernel/patches/` change the Linux kernel and are licensed like it,
**GPL-2.0** (the exFAT driver in 0004 is GPL-2.0-or-later). A published kernel `Image` comes
with its complete corresponding source as a release asset beside it: Sony's tree with the
patches applied, the `.config`, and the script it was built with (`kernel/release.sh`).

Sony's firmware, apps, libraries and images are Sony's. They are not covered by any licence
here, are not in this repository, and nothing built from them may be passed on. Each owner
brings their own firmware file and the key from their own player.
