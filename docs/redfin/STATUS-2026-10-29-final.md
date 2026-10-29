# redfin: state at the end of 2026-10-29 (final version of this session)

Read this first in a new chat. Pixel 5 (redfin, SM7250, Adreno 620, 8 GB) running iOS 16.7 on the
"SWEET" XNU (ios-sweet / ios-flame lineage). Repo: github.com/DenialOfGravity/ios-redfin (was
ios-flame-redfin), integration branch `redfin-int`. PC project folder: C:\ClaudeProjects\iOS_Pixel5.

## Known good (user-chosen final version)

| Part | Version | Where |
|---|---|---|
| Image | **r63a** (RAM only: `to-fastboot`, `boot r63a`) | PC folder r63a/, sha256 ad9ae3bf4a70d1bd… |
| Kernel | branch `ws-y-ram` aca60f4 (`known-good-r63a-kernel`), 262 patches, klog PA **0x101d0ef08** | builds/xnu/ws-y-ram-aca60f47b8 |
| Shim/ADT | r62b's shim with the 6 GiB RAM layout (base `ram62b`, made by tools/redfin-ram-base.py) | |
| btd (Bluetooth) | ws-y-bt 43320fd | /var/local/bin/btd-bridge (+ .knowngood) |
| wland (Wi-Fi) | ws-y-wland-restart 1363de7 | /var/local/bin/wland (+ .knowngood) |
| sensd (sensors) | ws-y-sensd-orient 3b82505 | /var/local/bin/sensd (+ .knowngood) |
| Metal bundle | ws-y-rotfb4 763f2e4 (SweetMetal2 sha256 f398d491…) | /System/Library/Extensions/SweetMetal2.bundle; binary copy /var/local/bin/SweetMetal2.knowngood |

Fallbacks: r62b (3.9 GiB RAM, same features) with the rotfb3 binary at /var/local/tmp/SweetMetal2.rotfb3;
bundle that predates all rotation work: /var/local/SweetMetal2.bundle.pre-rotfb.

## Kernel patch set (on top of the r55k line: 1030 Files/HFS-APFS compat)
- 1012 + 1013: Wi-Fi (diagnostics, country code / set 383). wifid joins ~20–35 s after the radio.
- 1016: Skywalk user-pipe privileges for entitled platform binaries → **headphone (A2DP) audio works**.
- 1031: orientation HID events carry CoreMotion's sensor-time child (vendor page 0xff15 usage 2) → **auto-rotate works**.
- 1032: UFS write guard (`kern.sweet_ufs_guard` 0/1 log (default)/2 enforce) + raw-device read panic fixed.
- 1033: XNU gets 6.0 GiB (0x100000000–0x27ec00000; was 3.9 GiB from sunfish's mkadt size); log stashes moved to
  0x27f000000 (pram), 0x27f200000 (klog mirror), 0x27f800000 (shim mailbox); hw.physmem/usermem capped instead of wrapping.
- NOT included: 1014 / 1014b (Wi-Fi signal events). With them the phone resets ~30–40 ms after wifid's join
  (also when wifianalyticsd's PHY_MODE is refused), so **no Wi-Fi signal bars in the status bar**.

## What works (user-confirmed 2026-10-29)
Boot, 90 Hz display, touch, GPU/Metal, storage + Files, speaker/mic, camera, haptics, torch, backlight, USB
networking; **Wi-Fi** comes up by itself at boot and joins when picked in Settings (pages load quickly);
**Bluetooth** scan, pairing, headphone music; **auto-rotate** (portrait→landscape ~3–5 s, landscape→portrait fast,
animated); **6 GiB RAM** (~392k pages of 16 KB; ~2.1 GB free after boot).

## Open issues (next steps)
1. Wi-Fi auto-join: wifid refuses the known networks "Below minimum RSSI threshold" at -40 dBm (kernel answers are
   the same as on good boots; wifid's learned fields + ThreeBars/analytics caches cleared without effect). Pick the
   network by hand. Unknown threshold source.
2. Wi-Fi signal bars: needs a 1014 variant that doesn't reset the phone on join; the trigger is in 1014's
   association-time code (not the PHY_MODE answer).
3. Landscape speed: CA renders landscape into a rotated framebuffer (ignores supportsRenderTargetTextureRotation=NO);
   metal2vulkan's shadow-copy path still costs tens of ms per frame. Next: render straight into the rotated layout,
   or one copy per frame. Rotated-texture reuse is partial (3 made / 1 reused).
4. bluetoothd: one SIGBUS at boot seen once in ExposureNotification (ENRegionMonitor _createLocationManager); restarts.
5. RAM: the low ~950 MB (0x80000000–0xbbb00000, around firmware carve-outs) is still unused by XNU (needs holes support).
6. Charging under iOS doesn't work: charge in fastboot. The user does NOT want an automatic return to fastboot in the kernel.

## Root causes found today (keep)
- Bluetooth: btd waited with poll() on /dev/btbridge → POLLNVAL (cdevsw without cdevsw_setkqueueok); IBS wake/sleep
  bytes were swapped (0xFD = wake, 0xFE = sleep, answer wake with 0xFC); headphone crash = denied Skywalk privilege 12000.
- Wi-Fi at boot: RPMh try-lock EBUSY race between wland and btd-bridge rail votes ("rpmh ldoa1 … -> 16" in klog).
- Auto-rotate: sensd's daemon never started (only a --list probe); CoreMotion dropped orientation events as stale
  (no sensor-time child); landscape freeze = rotated framebuffer texture refused (frontend dropped `rotation`), then
  slow + GPU-pool growth from per-encoder shadow copies.
- RAM: mkadt.py carried sunfish's 0xf8c00000 memory size.

## Tools / conventions
- Phone agent (PC): agent/inbox → agent/outbox, unique request names (`ask NAME "ACTION"`), actions: status, boot,
  to-fastboot, klog PA, phone CMD, files put/get, build xnu|userland|metal2|shim BRANCH, mkimage NAME KDIR BASE.
- Local builds fail on any non-allow-listed patch skip (tools-localbuild c99381b; 5 allow-listed).
- `devices/redfin/` (device.conf → docs/devices/redfin.md, pull-firmware.sh, soc-args.py --check).
- Phone tools: /var/local/bin/sctl (sysctl), oslogs, psx, pstack, pimg, imgdump.
- Every phone change is listed with its backup in the PC's KNOWN-GOOD.txt.
