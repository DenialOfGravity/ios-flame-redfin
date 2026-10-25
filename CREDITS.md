# Credits and licences

This repository is a fork of ios-sweet and keeps its [MIT License](LICENSE). The flame additions are under
the same licence (Copyright (c) 2026 the ios-flame contributors), with these exceptions:

- `xnu/patches/` modify Apple's XNU, which is under the **Apple Public Source License 2.0**. The patched
  files stay under the APSL 2.0.
- Files that came from other projects keep their own licence, listed below.

Nothing from Apple's iOS, Google's images or Qualcomm's firmware is in this repository; see the README for
what you need to fetch yourself.

## Projects this builds on

- **HackiOS** (OOSEX GANG, <https://github.com/oosexgang/hackios-xnu-userland>, MIT): `phone/audio/`
  (RedwoodAudio.driver, the CoreAudio HAL plug-in) is its `userland/src/audio_plugin.c`, unchanged; licence
  in `phone/audio/LICENSE.HackiOS`. Patch 0914 implements its `/dev/redwood-audio` and `/dev/redwood-haptic`
  interfaces for this phone. Patch 0915 (`bsd/dev/sweet_adsp.c`, `bsd/sys/redwood_audio.h`) is HackiOS's kernel
  `redwood_adsp.c` and `sys/redwood_audio.h` (<https://github.com/oosexgang/hackios-xnu-kernel>, APSL 2.0) with the
  Pixel 5's numbers; the commit message lists what changed.
  Patches 0952-0955 (`bsd/dev/sweet_sound.c`, `sweet_mic.c`, `sweet_guard.c`) carry over HackiOS's kernel
  `redwood_sound.c`/`redwood_mic.c` APR message layouts and its `redwood_guard.c` speaker guard (unchanged but for
  names), APSL 2.0. The CS35L41, ALC5513 (rt5514) and LPASS register sequences in `sweet_cs35l41.c`/`sweet_mic.c`
  were written from the redbull kernel's `sound/soc/codecs/cs35l41*.c`, `rt5514.c`, `rl6231.c` and
  `techpack/audio` (GPL-2.0; LineageOS android_kernel_google_redbull) and the phone's device tree.

- **ios-sweet** (dipa-studio, <https://github.com/dipa-studio/ios-sweet>, MIT): the XNU port to the Redmi
  Note 10 Pro this is forked from. Patches 0001-0081, the shim and most of `tools/` started there.
- **XNU** (Apple, APSL 2.0): xnu-8796.141.3.
- **ios-topaz** (MakrSas, <https://github.com/MakrSas/ios-topaz>): the Redmi Note 12 4G fork of ios-sweet.
  - `phone/wifi/radio.c` is a userland port of its TopazModem radio (its patches 0123-0130).
  - Our patch 0123 contains its 0900 (en0 + Apple80211 for wifid) and 0128 (IOKit quiesce).
  - ios-topaz's CREDITS.md puts the HackiOS-derived kernel parts under the APSL 2.0.
- **HackiOS** (OOSEX GANG, <https://github.com/oosexgang/hackios-xnu-kernel>, APSL 2.0): the origin of the
  Apple80211/wifid code above (`redwood_net`, `redwood_apple80211`, `redwood_sta`, `RedwoodWLAN`,
  `MiniIONetworkStack`), the keystore wrap/unwrap and the 10-bit surface formats in 0123/0124.
- **UniXNU** (<https://github.com/UniXNU/UniXNU>, BSD-2-Clause-Patent at the top level):
  - `phone/metal2/NativeBridgeMetalFrontend.mm`: NativeMetal, MIT, patched for iOS 16.
  - `phone/metal2/bridge/` (NativeMetalBridge/NativeMetalObjects): NativeMetal, MIT; see `bridge/LICENSE`.
  - `phone/turnip/NativeAdrenoABI.h`: NativeAdreno, MIT.
  - The Mesa patches that `tools/build-turnip-ios.sh` applies; fetched, not copied.
- **metal2vulkan** (<https://github.com/steelbrain/metal2vulkan>, GPL-2.0-or-later OR LGPL-3.0-or-later):
  fetched at UniXNU's pin by `tools/build-m2v-bridge.sh`. `phone/metal2/bridge/patches/` are patches to it and
  fall under its licence. A built SweetMetal2.bundle links it statically.
- **Mesa / Turnip** (<https://gitlab.freedesktop.org/mesa/mesa>, MIT): the Vulkan driver for the Adreno 640,
  fetched by `tools/build-turnip-ios.sh`. `phone/turnip/patches/` are patches to it.
- **Linux**: `phone/wifi/` follows the drivers named in each file's header: ath10k (ISC) and the Qualcomm SMEM,
  SMP2P, GLINK, QRTR and remoteproc drivers (GPL-2.0). It also follows Bjorn Andersson's rmtfs, pd-mapper and
  tqftpserv for those protocols. The FTS touch driver (patch 0085) was written from Google's `fts_touch`
  module (GPL-2.0) and the phone's device tree.
- **blacktop/darwin-xnu-build** (<https://github.com/blacktop/darwin-xnu-build>, MIT): the XNU build.
- Fetched and built by the user, not in git:
  - Google's factory image, AOSP `mkbootimg` and `avbtool` (Apache 2.0)
  - TWRP
  - dropbear (MIT), toybox (0BSD) and dash (BSD)
