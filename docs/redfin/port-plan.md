# iOS on Pixel 5 (redfin) — port plan

Branch `redfin`, forked from `sunfish` (Yofuness/ios-flame @ dbda2ab, 2026-10-23), the Pixel 4a port of
ios-flame / ios-sweet. Started 2026-10-23. Test phone: Pixel 5, bootloader unlocked, stock
`UP1A.231105.001.B2` (Android 14).

Sources for every value below: LineageOS `android_kernel_google_redbull` (lineage-22.2), the
`arch/arm64/boot/dts/vendor/qcom/lito*.dtsi` (SM7250) and `google/lito-redbull*`/`lito-redfin*` trees,
`drivers/gpu/msm/adreno-gpulist.h`, `drivers/input/touchscreen/sec_touch/`, `drivers/clk/qcom/gcc-lito.c`,
`drivers/pinctrl/qcom/pinctrl-lito.c`, `drivers/soc/qcom/qcom_ipcc.c`, and LineageOS
`android_device_google_redbull` BoardConfig. **Source DT ≠ live DT.** Everything marked *verify* has to be
confirmed against the phone (`tools/redfin-recon.ps1 twrp`) before it is relied on.

Nothing here has run on a phone yet. Kernel patches 0150-0151 have not been compiled (no macOS build yet):
they apply cleanly on 0001-0149, and the new touch driver passes `clang -Wall -Wextra -fsyntax-only` with
stub headers.

## Why sunfish is the right base

| | flame (Pixel 4) | sunfish (Pixel 4a) | **redfin (Pixel 5)** |
|---|---|---|---|
| SoC | SM8150 | SM7150 (sdmmagpie) | **SM7250 (lito), v2** |
| CPU | 4xA55 + 4xA76 | 6xA55 + 2xA76 | 6xA55 + 2xA76 (1 prime) |
| GPU | A640, GMU HFI v2 | A618, legacy GMU (HFI v1) | **A620, GMU HFI v2 (a650 fw)** — closer to flame |
| Panel | NT37280 cmd-mode DSC | 1080x2340 | **S6E3HC2 cmd-mode DSC, 1080x2340, 2x540 slices, 60/90 Hz** |
| Touch | ST FTS, SPI | ST FTS, I2C | **Samsung sec_ts (S6SY79x), SPI** — new driver (0151) |
| PMICs | PM8150 + PM8150B/L | PM6150 + PM6150L | PM8150 (SID0) + PM8150L (SID4) + PM7250B (SID2) |
| Modem/AOP doorbell | APCS IPC | APCS IPC | **IPCC mailbox @0x408000** |
| Wi-Fi | WCN3990 (icnss) | WCN3990 (icnss) | WCN3998 (icnss) |
| Boot image | header v2, DTB in boot | header v2, DTB in boot | **header v3 + vendor_boot** |
| RAM | 6 GB | 6 GB | 8 GB |

## Hardware facts (from source DT)

| Item | sunfish (in code) | redfin | Source | State |
|---|---|---|---|---|
| Boot header | v2, dtb in image | **v3**, DTB + vendor ramdisk from `vendor_boot` | BoardConfig-common.mk | shim/build.sh |
| boot partition (AVB footer) | 0x04000000 | **0x06000000** | BOARD_BOOTIMAGE_PARTITION_SIZE | shim/build.sh |
| Ramdisk position | payload at initrd-start | **after vendor ramdisk, unaligned** | ABL v3 | loader.c scans + slides; *verify* in log |
| IMEM restart_reason | 0x146aa65c | **0x146ab65c** | lito.dtsi | shim.c |
| Splash framebuffer | 0x9c000000 / 0x1700000 | **0xa0000000 / 0x2300000** | lito.dtsi cont_splash_region | shim + 0150 |
| Panel | 1080x2340 | 1080x2340, cmd mode, DSC 2x540 | dsi-panel-s6e3hc2-dvt-dsc-1080p-cmd.dtsi | *verify* autorefresh |
| PON / reboot reason | PM6150 SID0 0x88f | PM8150 SID0 0x88f | pm8150.dtsi | same |
| Vol+ | PM6150L GPIO2 (0xc100) | **PM8150L GPIO5 (SID4, 0xc400)** | lito-redbull-common.dtsi | shim + 0150 |
| WDT / GIC / SPMI / PS_HOLD / UFS / apps SMMU | | same addresses | lito.dtsi | unchanged |
| USB HS PHY | 0x088e2000 | **femto @0x088e3000** (0x088e2000 = EUD), override `0xC7@0x6C 0xCC@0x70` | lito-usb.dtsi, lito-redfin-usb.dtsi | 0150 |
| Battery / charger | PM6150 SID0 | **PM7250B SID2** (qgauge@4800, charger 0x1000) | pm7250b.dtsi | 0150 |
| Touch | ST FTM5 I2C | **sec_ts, QUP0 SE0 SPI @0x880000**, mode 3, ≤10 MHz; IRQ TLMM 9, reset 8, bus switch 35; AVDD L17A 3.304 V | lito-redfin-touch.dtsi | 0151 |
| Touch clocks | | GCC vote 0x52008 bits 6-10, RCG 0x17010, CBCR 0x17004/8/c | gcc-lito.c | 0151 |
| TLMM | | 0x0f000000, tiles WEST +0x500000, EAST +0x900000 | pinctrl-lito.c | 0151 |
| RPMh cmd-db | AOP locator 0x0c3f000c | fixed region **0x80860000 + 0x20000** | lito.dtsi qcom,cmd-db | 0151 (fallback) |
| GPU regs / GMU / GPUCC / SMMU | 0x05000000 / … | **0x03d00000 / 0x03d6a000 / 0x03d90000 / 0x03da0000** | lito-gpu.dtsi | todo (step 8) |
| GPU chip ID / fw / zap | 0x06010800 / a618 | **0x06020001**, a650_gmu.bin + a650_sqe.fw, a620_zap @0x8bc15400 | lito-v2.dtsi, adreno-gpulist.h | mkpayload.py; kernel todo |
| Modem doorbells | APCS 0x17c0000c bits 12/14, AOSS 0 | **IPCC 0x408000+0xc**: MPSS glink (2,0), MPSS smp2p (2,2), AOP (0,0) | lito.dtsi, qcom_ipcc.c | phone/wifi/ipcc.h |
| SMEM | 0x86000000 | **0x80900000** | lito.dtsi smem_mem | phone/wifi/smem.h |
| MPSS region | 0x8b000000 + 0x9800000 | **0x8c000000 + 0x11800000** | lito-redbull-memory.dtsi | wland.c; *verify* |
| WLAN MSA | 0x98d00000 + 0x100000 | **0x8ba00000 + 0x200000** | icnss wlan-msa-fixed-region | wlfw.c; *verify* |
| WLAN SID | 0x240 | **0xC0** | lito.dtsi icnss iommus | radio.c |
| WLAN rails | L9A, L1C, L2C, L11C, L10C | **L1A (enable only), L14A 1.8, L2C 1.304, L11C/L10C 3.312** | lito.dtsi icnss | wland.c |
| WLAN ref clock | rfclka2 | *verify* (not in lito icnss node) | | wland.c unchanged |
| WLAN BDF | bdwlan-sunfish.bin | *verify* name (recon lists modem image) | | wlfw.c placeholder |
| RAM | ends 0x1fcc00000 | 8 GB, *verify* map | live DT | keep sunfish layout first |

## Done so far

**Shim** (boots in place of iBoot)
- Boot image header v3, AVB footer for the 0x06000000 boot partition, os_patch_level 2023-11.
- `find_payload()`: searches the initrd for the payload and realigns it (host-tested).
- Restart reason, framebuffer, vol+ pull-up for redfin.
- `SHIM_NO_UFS_WRITE`: compiles every UFS write out (checked in the disassembly) for probes while
  userdata still holds Android data. A Python fallback replaces `cpio` for the empty ramdisk.
- Built here: `redfin-probe1.img` = `SHIM_NO_UFS_WRITE` + `SHIM_HOLDLOG` (log held on screen 60 s, then
  reset to fastboot). Valid v3 header + AVB footer (unpack_bootimg, avbtool info_image).

**Kernel** (`xnu/patches/0150-*`, `0151-*`, see NOTES.md "Redfin patches")
- 0150 basics, 0151 sec_ts touch. The event decoding matches Linux's bitfield struct (100k random events).

**Phone userland** — Wi-Fi addresses and the IPCC doorbell (`phone/wifi/ipcc.h`).

**Host tools**
- `tools/redfin-backup.ps1`: every partition except userdata/super, from TWRP, SHA-256 checked.
- `tools/redfin-recon.ps1` / `.sh`: live DT, RAM map, partitions, firmware (read-only mounts).
- `tools/redfin-boot.sh`: touch, GPU off by default.

**CI** (no Mac needed)
- `.github/workflows/xnu.yml`, `userland.yml`, `metal2.yml` now also run on pushes to `redfin`
  (GitHub's macOS runners: kernel, wland/dropbear/phone tools, Metal).
- New `.github/workflows/shim.yml` (Ubuntu): builds `redfin-probe-safe.img` and `redfin-probe.img`.

## Bring-up order

Each step is a `fastboot boot` (RAM only). Nothing flashes boot-chain firmware.

**0. On Windows, now** — see "Windows steps" below. Backup, recon, then probe 1.

**1. Kernel builds in CI** — fork to your GitHub, push `redfin`, let `xnu` run. First goal: 0150/0151 compile.

**2. Probe-only shim** (`redfin-probe1.img`): expect the shim log on screen for 60 s, then a reset to
fastboot. Confirms v3 image accepted, DTB from vendor_boot, framebuffer, SPMI, restart reason. Photograph it.

**3. Shim + XNU payload** — needs the CI kernel, `mkadt.py` (RAM map from recon) and the iOS root on userdata
(this is the step that **wipes Android userdata**). Log line `loader: payload at … (initrd +N)`.

**4. Storage + root** — HFS+ root in userdata (mkiosroot.sh flow; needs a Linux VM or WSL for apfs-fuse).

**5. USB + SSH** — 0150's HS PHY. USB Ethernet, live log, SSH.

**6. Touch** — `sectouch=1 sectouchlog=1`.

**7. Wi-Fi** — wland with the redfin addresses, BDF from recon.

**8. GPU** — start from flame's A640 v2 HFI path (not sunfish's legacy A618 path) with the A620 constants
above, then Turnip.

## Windows steps

Tools: [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) on PATH
(`adb`, `fastboot`), and the official TWRP for redfin from twrp.me (Google Pixel 5 page). Run PowerShell in the
project folder. Scripts are read-only on the phone.

1. **Stock Android, USB debugging on:**
   `powershell -ExecutionPolicy Bypass -File tools\redfin-recon.ps1 android`
2. **Factory image:** download the `redfin` `UP1A.231105.001.B2` factory zip from Google's factory-images page
   and keep it (RECOVERY.md flow). It is the way back to stock.
3. **TWRP, RAM only:** `adb reboot bootloader`, then `fastboot boot twrp-<version>-redfin.img`.
   Don't use "Install" or flash anything from TWRP.
4. **Backup:** `powershell -ExecutionPolicy Bypass -File tools\redfin-backup.ps1`. It writes to `backup\` with
   hashes in `backup\backup-log.txt`. Copy it off the PC as well. It contains your IMEI/calibration partitions.
5. **Recon:** `powershell -ExecutionPolicy Bypass -File tools\redfin-recon.ps1 twrp`. It writes to `recon\`.
6. **Probe 1:** `adb reboot bootloader`, then `fastboot boot redfin-probe1.img`. Watch and photograph the
   screen. After about 60 s it should reset back to fastboot. If it hangs, hold Power about 30 s. Then
   `fastboot reboot` returns to Android, untouched.

## Open questions

- Does the Pixel 5 ABL leave INTF autorefresh on for the cmd-mode panel (flame did)?
- Exact initrd offset of our ramdisk on v3 (probe log).
- Live RAM map with 8 GB, and where the top-of-RAM log stashes can go.
- Does XBL/ABL load SPI firmware on QUP0 SE0? The touch driver checks it and stops if not.
- WLAN reference clock resource on lito, and the BDF file name.
- Is the rmtfs buffer size (DT 0x280000 vs our 0x200000) significant for the lito modem?
