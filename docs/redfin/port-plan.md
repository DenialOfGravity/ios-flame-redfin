# iOS on Pixel 5 (redfin) — port plan

Branch `redfin`, forked from `sunfish` (Yofuness/ios-flame @ dbda2ab, 2026-10-23), which is the Pixel 4a port
of ios-flame / ios-sweet. Started 2026-10-23.

Sources for every value below: LineageOS `android_kernel_google_redbull` (branch lineage-22.2), the
`arch/arm64/boot/dts/vendor/qcom/lito*.dtsi` (SM7250 SoC) and `google/lito-redbull*/lito-redfin*` (board)
trees, `drivers/gpu/msm/adreno-gpulist.h`, and LineageOS `android_device_google_redbull` BoardConfig.
**Source DT ≠ live DT.** Everything marked *verify* has to be confirmed against the phone with
`tools/redfin-recon.sh twrp` before it goes into a kernel patch.

## Why sunfish is the right base

| | flame (Pixel 4) | sunfish (Pixel 4a) | **redfin (Pixel 5)** |
|---|---|---|---|
| SoC | SM8150 | SM7150 (sdmmagpie) | **SM7250 (lito), v2** |
| CPU | 4xA55 + 4xA76 | 6xA55 + 2xA76 | 6xA55 + 2xA76 (1 prime) — same cores |
| GPU | A640, GMU HFI v2 | A618, legacy GMU (HFI v1) | **A620, GMU HFI v2 (a650 fw)** — closer to flame |
| Panel | NT37280 cmd-mode DSC | 1080x2340 | **S6E3HC2 cmd-mode DSC, 1080x2340, 2x540 slices, 60/90 Hz** — closer to flame |
| Touch | ST FTS, SPI | ST FTS, I2C | **Samsung sec_ts, SPI** — new driver |
| PMICs | PM8150 + PM8150B/L | PM6150 + PM6150L | PM8150 (SID0) + PM8150L (SID4) + PM7250B (SID2) |
| Wi-Fi | WCN3990 (icnss) | WCN3990 (icnss) | WCN3998 (icnss) — same family |
| Boot image | header v2, DTB in boot | header v2, DTB in boot | **header v3 + vendor_boot** |
| RAM | 6 GB | 6 GB | 8 GB |

Display, storage, keys, PSCI, GIC, watchdog, SPMI arbiter, PS_HOLD, UFS controller and the USB controller sit at
the same addresses as on sunfish/flame. The real work is in four places: **boot image v3**, **touch**, **GPU**,
and **Wi-Fi addresses**.

## Hardware facts (from source DT)

| Item | sunfish (in code) | redfin | Source | State |
|---|---|---|---|---|
| Boot header | v2, base 0, kernel 0x8000, dtb in image | **v3**, page 4096, DTB + vendor ramdisk from `vendor_boot` | BoardConfig-common.mk | changed in shim/build.sh |
| boot partition (AVB footer size) | 0x04000000 | **0x06000000** | BOARD_BOOTIMAGE_PARTITION_SIZE | changed |
| Ramdisk position | payload at initrd-start | **after vendor ramdisk, unaligned** (ABL concatenates) | ABL v3 behaviour | loader.c scans + slides; *verify* offset in shim log |
| IMEM restart_reason | 0x146aa65c | **0x146ab65c** | lito.dtsi msm-imem@146ab000 | changed |
| Splash framebuffer | 0x9c000000 / 0x1700000 | **0xa0000000 / 0x2300000** | lito.dtsi cont_splash_region | changed (shim); kernel SWEET.h *todo* |
| Panel | 1080x2340 | 1080x2340, cmd mode, DSC 2x540 | dsi-panel-s6e3hc2-dvt-dsc-1080p-cmd.dtsi | ABL leaves it running; *verify* autorefresh like flame |
| PON / reboot reason | PM6150 SID0 0x88f | PM8150 SID0 0x88f | pm8150.dtsi | same register |
| Vol+ | PM6150L GPIO2 (SID4, 0xc100) | **PM8150L GPIO5 (SID4, 0xc400)** | lito-redbull-common.dtsi gpio_keys | changed (shim); kernel 0126 *todo* |
| Power / vol- | PON KPDPWR / RESIN | same | | |
| WDT / GIC / SPMI / PS_HOLD | 0x17c10000 / 0x17a00000 / 0xc440000 / 0xc264000 | same | lito.dtsi | unchanged |
| UFS | 0x1d84000 | 0x1d84000 | lito.dtsi | unchanged (shim finds userdata via GPT) |
| USB | DWC3 0xa600000 | DWC3 0xa600000, **SNPS femto HS PHY 0x88e3000** (0x88e2000 is EUD), QMP USB/DP PHY 0x88e8000 | lito-usb.dtsi | kernel 0088 PHY base *todo* |
| Touch | ST FTM5, I2C SE7 0x49 | **sec_ts on QUP SE0 SPI @0x880000**, CS0, 10 MHz, CPOL/CPHA=1; IRQ TLMM 9 (level low); reset TLMM 8; bus switch TLMM 35 (low); AVDD pm8150_l17 3.3 V always-on | lito-redfin-touch.dtsi, lito-qupv3.dtsi | **new driver** |
| GPU regs | 0x05000000 | **0x03d00000** | lito-gpu.dtsi kgsl-3d0 | *todo* |
| GMU | 0x0506a000 | **0x03d6a000** | lito-gpu.dtsi | *todo* |
| GPUCC | 0x05090000 | **0x03d90000** | lito.dtsi gpucc | *todo* |
| GPU SMMU | 0x05040000 | **0x03da0000** | lito-gpu.dtsi kgsl-smmu | *todo* |
| SIDs | GPU 0/2, GMU 4/5 | GPU 0 (mask 0x401) / 2, GMU user 4 / kernel 5 (mask 0x400) | lito-gpu.dtsi | *verify* mask (sunfish needed mask 0) |
| Chip ID | 0x06010800 | **0x06020001** (lito-v2) | lito-v2.dtsi | *todo* |
| GPU firmware | a618_gmu, a630_sqe, a615_zap | **a650_gmu.bin, a650_sqe.fw, a620_zap** | adreno-gpulist.h | mkpayload.py changed; kernel names *todo* |
| Zap region | 0x98f95000 | **0x8bc15400** (0x2000, not page aligned) | lito.dtsi pil_gpu_mem | *todo* |
| GPU max clock | 825 MHz | 625 MHz (v2 bins) | lito-v2.dtsi pwrlevels | *todo* |
| Wi-Fi | icnss SID 0x240 | icnss @0x18800000, **SID 0xC0** | lito.dtsi | phone/wifi/radio.c *todo* |
| Modem / WLAN memory | MPSS 0x8b000000, MSA 0x98d00000 | **modem_wlan_mem 0x8c000000 + 0x11800000**, pil_wlan_fw 0x8ba00000 | lito.dtsi, redbull-memory.dtsi | *verify* where MSA lands; wland.c / wlfw.c *todo* |
| WLAN BDF | bdwlan-sunfish.bin | *verify* name in /vendor/firmware_mnt | | |
| RAM | ends 0x1fcc00000 | 8 GB, *verify* map | live DT | keep sunfish layout first (XNU up to 0x1f8c00000), grow later |

## What this branch changes so far

1. `shim/build.sh` — boot image header v3 (no offsets, no DTB), AVB footer padded to 0x06000000.
2. `shim/loader.c` — `find_payload()`: scans the initrd for `SWEETXNU` and slides the payload onto an 8-byte
   boundary if ABL put it after an odd-length vendor ramdisk. Host-tested at offsets 0, 8, 13, 4095, 1234567.
3. `shim/shim.c` — IMEM restart reason 0x146ab65c; vol+ pull-up on PM8150L GPIO5; sunfish touch-power GPIO
   removed (redfin touch power is an always-on LDO).
4. `shim/console.h`, `shim/mmu.h` — splash framebuffer at 0xa0000000, 0x2300000.
5. `tools/mkpayload.py` — A620 firmware names.
6. `tools/redfin-boot.sh` — sunfish-boot.sh with touch and GPU off (CPU rendering) by default.
7. `tools/redfin-recon.sh` — read-only collection of live DT, RAM map, partitions, boot headers, firmware.

The shim compiles and links (no absolute relocations); the boot image itself has not been built here
(mkbootimg/avbtool weren't reachable from the build machine) or run on a phone.

Not touched yet, deliberately: `shim/gpuprobe.c` (SHIM_DIAG only, A640/A618 addresses), `shim/ramlog.c` and
`tools/mkadt.py` memory layout (wait for the live RAM map), and all kernel patches.

## Bring-up order

Each step is a `fastboot boot` (RAM only). Nothing below flashes boot-chain firmware.

**0. Prerequisites (you)**
- Pixel 5 on the final redfin factory image, bootloader unlocked (`fastboot flashing unlock` wipes it).
- Keep the matching factory image zip in `images/` (RECOVERY.md flow).
- Back up per-device partitions into `backup/` (persist, modemst1/2, fsg, fsc, …). They hold the IMEI and
  calibration data; never commit them.
- Host: Windows is fine for adb/fastboot, recon and the shim (Git Bash or WSL + llvm/lld/lz4 + AOSP
  mkbootimg/avbtool). **The XNU kernel and the iOS-side code (`ios-cc`, Xcode iOS SDK, darwin-xnu-build) need
  macOS with Xcode**, as for flame/sunfish.
- A recovery with adb root for redfin, to write the root image and pull logs (TWRP or Lineage recovery; *verify*
  which `fastboot boot`s cleanly on a v3 device — some need vendor_boot from the same build).

**1. Recon** — `tools/redfin-recon.sh android`, then in recovery `tools/redfin-recon.sh twrp`, then
`tools/redfin-recon.sh images images/<factory>/` on the unpacked factory image. This fills every *verify*.

**2. Probe-only shim** — `shim/build.sh` with no payload, `fastboot boot shim/out/shim-boot.img`. Expect the
console on the splash buffer and a reset back to fastboot (PON reason). Confirms: v3 image accepted, DTB from
vendor_boot, framebuffer, SPMI, restart reason. Read the shim log from userdata scratch (sunfish-log-pull.sh).

**3. Shim + XNU payload** — log line `loader: payload at … (initrd +N)` confirms the v3 ramdisk handling.
Kernel patch `0150-redfin-basics`: FB base 0xa0000000 in SWEET.h, vol+ PM8150L GPIO5, IMEM. Goal: XNU console
on screen.

**4. Storage + root** — HFS+ root in userdata (same mkiosroot.sh flow). Goal: launchd, SpringBoard, CPU-rendered.

**5. USB + SSH** — patch 0088's HS PHY base → 0x88e3000. Goal: USB Ethernet, live log, `ssh`.

**6. Touch** — new `sweet_sects` driver: GENI SPI on SE0 (reuse flame's GENI SPI code from 0085, which was
SE at 0x890000), Samsung sec_ts protocol (Linux `drivers/input/touchscreen/sec_ts` in the redbull tree).

**7. Wi-Fi** — wland with SID 0xC0, modem/MSA addresses from recon, redfin BDF.

**8. GPU** — start from flame's A640 v2 HFI path (not sunfish's legacy A618 path), with A620 addresses,
chip ID, a650 GMU/SQE firmware, a620 zap at 0x8bc15400, then Turnip (Mesa supports A620; *verify* in the
pinned Mesa version).

## Open questions

- Does Pixel 5 ABL leave INTF autorefresh on for the cmd-mode panel (flame did; the shim's `sde_autorefresh`)?
- Exact initrd offset of our ramdisk on v3 (logged by the shim in step 2/3).
- Live RAM map with 8 GB and where the top-of-RAM log stashes (0x1fa000000 mirror, 0x1fbe00000 mailbox) can go.
- Is touch AVDD (pm8150_l17) actually on after ABL, or does it need an RPMh vote?
