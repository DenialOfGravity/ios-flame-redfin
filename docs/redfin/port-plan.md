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
| WLAN ref clock | none | icnss node has no clocks; lito cmd-db has no rfclka2 | | wland votes only if cmd-db has it |
| WLAN BDF | bdwlan-sunfish.bin | *verify* name (recon lists modem image) | | wlfw.c placeholder |
| RAM | ends 0x1fcc00000 | 8 GB, *verify* map | live DT | keep sunfish layout first |

## Recon results (live DT from TWRP, 2026-10-23)

Phone: `Google Inc. MSM sm7250 v2 Redfin PVT`, MP1.0, bootloader `r3-0.6-10489834`, slot `_a`, unlocked.
Backup of all 75 partitions except userdata/super, SHA-256 checked, in `backup\` (private).

Confirmed against the live DT (no changes needed): splash 0xa0000000+0x2300000; IMEM restart_reason
@0x146ab65c; SMEM 0x80900000; cmd-db 0x80860000+0x20000; pil_wlan_fw 0x8ba00000+0x200000; modem_wlan
0x8c000000+0x11800000; pil_gpu 0x8bc15400+0x2000; IPCC @0x408000; icnss SID 0xC0/0x1 and rails
L1A/L14A/L2C/L11C/L10C; touch `sec,sec_ts` on spi@880000 (mode 3, 10 MHz, IRQ 9, reset 8, switch 35,
1080x2340); vol+ PM8150L GPIO5; HS PHY @0x88e3000; CPUs MPIDR core<<8; panel
`qcom,mdss_dsi_s6e3hc2_dvt_dsc_1080p_cmd`.

- **RAM**: <0x80000000 0x3bb00000>, <0xc0000000 0xc0000000>, <0x180000000 0x100000000> = continuous
  0xc0000000-0x280000000. XNU's sunfish window 0x100000000-0x1f8c00000 and the log stashes at
  0x1f9000000-0x1fcc00000 are plain RAM with no reserved regions: layout kept. `mkadt.py` FB updated.
  Reserved regions below 4 GB besides the carve-outs: 0xb7e01000-0xb8652000, 0xc8000000+0x10000 (outside
  XNU and outside the 0xE0000000 pools).
- **userdata** = `sda19`, start 20873216 x 512 B (4K LBA 0x27d000, confirmed by probe 1), 228818904 x 512 B; 4K logical blocks.
- **GPU**: DT `qcom,chipid = <0x6020000>` (not lito-v2's 0x06020001; kgsl reads the real ID from hardware).
  Firmware present: a650_gmu.bin, a650_sqe.fw, a620_zap.mdt/.b00-.b02 (pulled to `recon\fw`).
- **Wi-Fi**: wlanmdsp.mbn, modemuw.jsn and the BDFs (`bdwlan-redfin.bin`, `bdwlan-u-redfin.bin`) are in
  `/vendor/firmware`, not the modem partition. `wlfw.c` now uses bdwlan-redfin.bin.

## Probe 1 (2026-10-23, `redfin-probe1.img`): shim runs on the Pixel 5

Photo of the held log: v3 boot image accepted; console on 0xa0000000; EL1, MIDR 0x51df805e, MPIDR
0x81000000; DTB at 0xae200000 from vendor_boot; initrd 0xafe00000-0xb1abfaa0 (about 30 MB: vendor
ramdisk first, ours last, as predicted); PSCI 1.1 (CPU_ON/RESET/RESET2 yes, SYSTEM_SUSPEND no); SPMI arb
v5, 512 APIDs; PON reason set (0x10 -> 4) and IMEM 0x77665500; PS_HOLD hard reset armed; vol+ PM8150L
GPIO5 found (subtype 0x10, reads high = released); UFS 3.0 asleep (TUR sense key 2), woken by SSU,
userdata 0x27d000 + 0x1b46ffb blocks (= recon); writes refused by SHIM_NO_UFS_WRITE (`save: write rc -1`);
SDE hw 0x60010000, CTL0 drives DSC0+DSC1 into INTF1 (as flame). The screen ended at ctl4: probe 2
pages the log (20 s per page) to see the rest (autorefresh, loader, GIC, RAM).

## Probe 2 (2026-10-23, `redfin-probe2.img`, log paged): the rest of the log

- Scanout as ABL leaves it: SSPP VIG0 + VIG1, each 540x2340, both at 0xa0000000, stride 0x10e0 (4320),
  a8r8g8b8 (fmt 0x237ff); CTL0 @0xae02000 -> LM0/LM1 (@0xae45000/0xae46000) -> PP0/PP1 (@0xae71000/
  0xae71800) -> DSC0 (@0xae81000) -> INTF1 (@0xae6b800). Same shape as flame.
- **Autorefresh: ABL already leaves it on** (`ctl ae02000 pipe ae05000 tear 1 autorefresh 80000001`); the
  shim keeps it, and the frame/line counters keep advancing over the sample window (e.g. 9b1 -> 1124
  frames). The command-mode panel scans out the splash buffer by itself, so the XNU early console and
  SweetFB's CPU path need no display driver work to start.
- Loader: `no SWEETXNU payload` (expected: probe image, empty ramdisk). initrd 0xafe00000-0xb1abfaa0.
- GIC-600: GICD ctlr 0x10, typer 0x7b041d, iidr 0x201143b; 8 redistributors (typer 0:21 .. 700:731),
  all awake (waker 0).
- RAM probes at 0x100000000, 0x180000000 and 0x1fbf00000 read back the test pattern: the XNU window and
  the log-stash area are writable RAM.
- Ended with `done, resetting`.

**The shim side of bring-up is done for now.** What's left before an XNU boot: a kernel from CI
(0150/0151 must compile), the ADT (`mkadt.py --highmem`, FB already updated), and the iOS root on
userdata (wipes Android data).

## First CI build and kernel boot image (2026-10-23)

Fork: github.com/DenialOfGravity/ios-flame-redfin, branch `redfin`. CI on push: shim, userland
(wland built with the redfin changes), metal2, xnu: all green. xnu artifact `kernel.development.sweet`
(sha256 906b776f…) contains `SWEET SECTS`, `sectouch`, the lito cmd-db fallback and the flame FTS
default-off: 0150 and 0151 compiled and linked.

`redfin-k1-readonly.img` = that kernel + `mkadt.py --highmem` ADT + shim built with
`SHIM_NO_UFS_WRITE`. Boot-args: `rd=ufsroot0 ufsrw=0 rootrw=0 sweetlog=0` (the kernel refuses every UFS
write and starts no log thread), `flamereboot=150`, touch/GPU/Metal off, **`sweetusb=0`**.
Expected: XNU early console on screen, then "waiting for root device" (userdata is still Android's).

Found while checking startup writers:
- **USB SMMU stream is hard-coded 0x140** in sweet_usb.c (flame/sunfish); redfin's DWC3 is
  `iommus = <&apps_smmu 0xe0 0x0>`. Next patch (0152) before `sweetusb=2`. GCC USB clock/GDSC offsets
  also still unverified for lito.
- cpufreq-hw on lito: 0x18323000 / 0x18325800 (same as sunfish, same LUT 0x110 / perf state 0x920)
  **plus a prime cluster at 0x18327800** the driver doesn't know yet (prime core stays at ABL's clock).
- Kernel has no LC_DYLD_CHAINED_FIXUPS (mkpayload `fixups: 0`), as expected for this build.
- `research/ipsw-x/d22ap.adt` (iPhone X device tree, /product node) is needed for userland, not here.

## First XNU boot (2026-10-23, `redfin-k1-readonly.img`): kernel runs

Photos of the screen: all 8 CPUs (`mcache: 8 CPU(s)`); AMFI/Sandbox stand-ins, SWEET HFS, Skywalk
self-tests PASSED, lo0/gif0/stf0; `SWEET UFS: "userdata" on LUN 0: first block 0x27d000, 111727 MiB,
read-only`; cpufreq pwrcl -> 1804 MHz, perfcl -> 2208 MHz (prime cluster untouched); keys found (pon APID
210, vol+ APID 271, subtype 0x10); battery `55% 3931mV external=1 charging=1` (PM7250B SID 2 works);
AMFI published; `BSD root: ufsroot0` -> HFS `unknown Volume Signature : 5d17` -> `cannot mount root,
errno = 19`, retried every few seconds (expected: Android data); `FLAME WDT: flamereboot=150 reached` ->
back in fastboot. Bottom-edge colour bar = start.s progress bar.

Kernel bring-up on redfin works first time. 0152 (USB SID/clocks, prime cpufreq) follows; then the iOS
root image on userdata.

## iOS boots on the Pixel 5 (2026-10-24, `redfin-r1-iosroot.img`)

Root image: `tools/redfin-mkroot-wsl.sh` in WSL (Ubuntu 26.04; WSL's kernel has no HFS+, so `hfsmod`
builds hfsplus.ko from the linux-msft-wsl-6.18.54.1 source with the running config and force-loads it:
gcc 15 vs Microsoft's gcc 13 only moves the genksyms CRCs). Written to sda19 with
`tools/redfin-install-root-wsl.sh` from TWRP, all 16 GiB SHA-256 verified.

Boot r1 = kernel 0151 + ADT with D22AP /product + `rd=ufsroot0 ufsrw=1 rootrw=1`, touch/USB/GPU off:
**iOS 16.7.16 (iPhone X userland) boots into the OS on the Pixel 5**; power and volume keys work.
Touch off by design (sectouch=0).

Next: r2 = kernel 0152 + `sectouch=1 sectouchlog=1` (first run of the sec_ts driver), USB still off.
Then USB: Windows has no CDC-ECM class driver (the port's USB Ethernet), so the host side needs work
(usbipd into WSL, or an NCM/RNDIS variant of sweet_usb).

## Touch works (2026-10-24, `redfin-r2-touch.img`)

Kernel 0152 + `sectouch=1`: the sec_ts SPI driver (0151) works first time; home screen, Settings >
General > About (iOS 16.7.16, iPhone X) all usable by touch. Display: with the GPU off, SweetFB's
CPU path copies the centre of the 1125x2436 iPhone X frame, cropping 48 px top and bottom; r3 uses
`sweetfb_native=1` (1080x2340 = 360x780 pt @3x, the iPhone 12 mini size, which UIKit knows).

Wi-Fi without USB/SSH: `tools/redfin-install-wifi-wsl.sh` puts wland/netsvc (CI ios-userland), modem +
vendor WLAN firmware (recon\fw), the phone's own rmtfs partitions (backup\) and the launchd job into
the image in WSL; `tools/redfin-install-root-wsl.sh delta` rewrites only the changed GiBs from TWRP.
r3 = r2 + `sweetfb_native=1`, `flamereboot=1800`.

r3 **hangs** after SpringBoard/backboardd start (console stays up); r2 boots the same root to the GUI, so
`sweetfb_native=1` is the cause (its kernel log was overwritten by the r2 boot: re-run r3 and pull
logs straight after to see why). Next images are based on r2.

## Wi-Fi round 1 (2026-10-24)

`tools/redfin-pull-logs-wsl.sh` (TWRP) pulls wland.log, the XNU ring and crash reports from the phone's
HFS+ root into `logs\<time>`. wland: SMMU (SID 0xc0 -> CB4) ok, rails L1A, L14A, L2C, L11C, L10C ok
(match the live icnss node), then `rfclka2 on -> 19`: kernel "rfclka2 lookup matches=0". lito's cmd-db
has no rfclka2 and the icnss node has no clocks, so wland now skips the vote when cmd-db lacks it,
makes the qdss AOSS message non-fatal and logs the cmd-db list (a2a825f). Crash reports were only
background extensions (Spotlight importers, TTS, mediaserverd) with the clock unset (1969).

Wi-Fi round 2 (rfclk fix): the modem boots (cx[7] mss[6], 99 MB loaded, ready after 100 ms), GLINK
and QRTR come up, rmtfs/pd-mapper/tftp serve, then ERR-FATAL 7 ms after the modem asked rmtfs for
2621440 bytes: wland's buffer was sunfish's 2 MB, so it refused. lito DT rmtfs_sharedmem is 0x280000;
BUF_SIZE is now 2.5 MB (0xe1001000-0xe1281000, System RAM on redfin, inside upstream 0150's GPU-pool
gap). wland now logs grant/refuse and the modem's crash reason (SMEM 421). Later, for the GPU:
kregistry_mem 0xc8000000 (64 KB) sits inside the first GPU pool range 0xc4000000-0xe0000000.

Wi-Fi round 3 + USB (2026-10-24, `redfin-r4-usb.img`, kernel 0903): **USB Ethernet works** (usbipd into
WSL, cdc_ether, live log over UDP 5140, file server 2223). Wi-Fi: modem + WLAN firmware up (WLAN.HL.3.3.1,
chip 0x320), 38 networks scanned on 2.4 and 5 GHz, **WPA2 join and 4-way handshake complete** on both bands,
rx frames reach en0, but en0 sends nothing: configd's preferences.plist (written by the first boots, before
en0 existed) has no network services, so no DHCP on en0 (same as flame 2026-10-22). Removed over USB;
redfin-install-wifi-wsl.sh now moves such a file aside.

Upstream sync (2026-10-24): merged Yofuness `sunfish` up to 8dcca4d (wland ath10k station steps +
wlan-steps.conf / wlan-scan.conf hooks, sunfish-wifitest.sh, xnu 0150 GPU pool vs rmtfs, 0151 QUSB2).
Redfin patches renamed 0900-0902 (+0903: QUSB2 off on redfin). Patch numbers above are the old ones.

Working copy: one git clone in WSL, `~/ios-redfin`; the PC folder keeps only `backup\` and `recon\`
(data the scripts read; never in git). Image and checksum list: `~/redfin-work`, `work/iosroot/`.

## GPU round 1 (2026-10-24): A620 kernel bring-up written, not booted yet

Upstream sunfish merged up to 16553aa (xnu 0152-0160: GPU hang detection by CP progress, ring-full waits,
per-client pool reuse, no WFI between submits, non-blocking present, 64-byte surface rows; Turnip 0101-0104;
metal2 bridge 0102). New: **0904** (Adreno 620) and **0905** (double-buffered present), see NOTES.md.

What 0904 takes from where (kgsl = LineageOS android_kernel_google_redbull lineage-22.2):
- A620 is A650 family in kgsl (`adreno_is_a650_family`): separate RSCC (DT `rscc` 0x3de0000), A650 RSC
  sequencer words, gmu_vma (DTCM at 0x10004000, cache window 16 KB-16 MB), TCS3 cmd1 data 2, vrm.soc TCS cmd 3,
  veto_fal10, APRIV, bicubic weights, hang cycles 0x3ffff, prim fifo 0x10000 + TSE skip off.
- a650_gmu.bin (recon\fw) asks for its cache memory itself: PREALLOC_REQ 0x4000+0x8000, 0x144000+0x13000,
  0x157000+0x9000; data blocks ITCM 0/0x200/0x400, cache 0x4000/0x157000, DTCM 0x10004000/0x10007fdc.
- a620_zap.mdt: one PT_LOAD (b02, paddr 0x5000, 0x68c bytes) into pil_gpu_region 0x8bc15400.
- Live DT: kgsl-smmu has 5 SMRs ("stream matching with 5 register groups"), CB5-7 hyp-protected,
  `qcom,actlr` 0x32b (not written), no attach-impl-defs; DT masks GMU <5 0x400>, GPU <0 0x401>.
- Mesa 85fda3b3 has FD620 (gen1, 1 CCU, 512 KB GMEM): Turnip needs no device patch.

**Boot r6 (GPU probe):** `GPU=1 tools/redfin-boot.sh r6 KERNEL sectouch=1 sectouchdelay=20` (kernel from CI with
0904/0905). sweetgpu=1, present thread on, CA still on the CPU. Expect in the live log (`SWEET GPU:`):
`rpmh: cmd-db mx.lvl ...`, `gmu: cache 4000 + 8000 -> pool + 10000` (3 lines), `gmu: N firmware blocks loaded`,
`gmu: init result 100 BOOTED`, `hfi: bw cmd-db CN0 ...`, `hfi: perf/bw tables ... -> 0`, `oob gpu_set acked`,
`ring me_init ... idle`, `zap: auth and reset rc 0`, `bring-up done, GPU ready`, then
`SWEET FB: frames now scaled to fit by the GPU`. Any `TIMEOUT` line says which stage to look at; the trail
copy at 0xe2000000 survives a warm reset.
**r7:** r6 + `FLIP=1` (tear-free present). **r8:** `GPU=2` (Metal on Turnip; blur, materials and Safari need
it: CA's CPU renderer has no blur) after installing the metal2 CI bundle (tools/sunfish-metal2-install.sh
works over the same USB address once dropbear is on the root).

## GPU works (2026-10-24, r9-metal, kernel with 0904-0908)

r8's GPU trail (`/dev/pmem` 0xE2000000): GMU booted (init result 0x100), cmd-db mx 0x30010 / cx 0x30000 /
xo 0x300a0 / vrm.soc 0x43400, HFI tables acked at 500 MHz, GX on, SMRs with DT masks kept (84000005,
84010000), ME_INIT idle, then PAS mem setup refused pil_gpu_region 0x8bc15400 (0xffcfffba). 0908 tries a
1 MB-aligned region first (a620_zap's p_align): r9 boots with the GPU, Metal on Turnip (SpringBoard, WebKit),
blur right, the iPhone X frame scaled to fit. ~5 % GPU busy at 20 presents/s idle. Metal also needed
`/var/local/m2v-cache` mode 777 (SpringBoard runs as mobile). Wi-Fi: wifid joined only ~10 min after the
radio was ready, then worked. Brightness (0906), vibration (0907): no result yet (live log started late).

**r10 (kernel with 0909, `sweetbl=1 sweethaptic=2`):** vibration works (boot buzz, `flame-cmd.py 'v 300'`), not
yet driven by iOS; the brightness slider changes the panel through DCS 0x51, no visible cost with the GPU.
Sensors: the live DT has no accelerometer, gyro, light or proximity node on an APPS bus: they sit behind the
ADSP's sensor core (SSC, QMI), like audio. APPS-reachable extras: the PM8150L flash LED (qpnp-flash-led-v2 @0xd300).

### Other ports checked (2026-10-24)
- joranv1/ios-sailfish (Pixel 1, A530): GL path, not Metal: Mesa freedreno GLES in backboardd (sweetgl.dylib
  + EAGL shim) with CA's GL renderer; blur because sweetgl supplies CA's missing GL texture functions (variable
  blur 0x26/0x27, colour matrix 0x14, vibrant 0x2d) and emulates framebuffer fetch. Taken over: the
  double-buffered present (0164 -> 0905). Candidates next: interrupts for touch (0181, GICv3 SPI attach; sec_ts
  IRQ is TLMM 9), touch move coalescing (0182 `sweettouchhz`), panel brightness by DCS 0x51 (0168), display
  sleep via the mixer (0167), CPU boost (0183: on redfin the prime core at 0x18327800 is the analogue).
- Yofuness/ios-flame `sunfish` (Pixel 4a, A618): Metal on Turnip works; merged.
- SourceQuality/ios-taimen (Pixel 2 XL, A540), Asuniia/ios-kirin, jiracipika/ios-sailfish (pixel7 branch):
  GL path like sailfish (taimen ~60 fps by write-combined Mesa heap + seed-based surface flushes: the Metal
  path already maps its buffers write-combined).
- MakrSas/ios-topaz (Redmi Note 12, A610): GPU-pool patches, audio, 4K pages. zeroninefourfour/ios-extra:
  A618 GMU experiments. tutpyhoon/ios-coral (Pixel 4 XL, A640): flame tree on coral, no new GPU work.

## Haptics, audio DSP (2026-10-24, r11-r14c)

- **Touch on its interrupt** (0911): TLMM gpio9 -> summary SPI 208 (INTID 240), events every ~5 ms.
- **Network** (0913): WebKit networking, nsurlsessiond, trustd and mDNSResponder were denied socket delegation;
  granted to platform binaries. Wi-Fi joins in about 75 s after the idle-cache fix (0910).
- **Haptics work** (r13c): iOS plays them as waveforms on the iPhone X's "Actuator" audio device. Needed:
  /product/haptics closed-loop in the ADT (mkadt.py), HackiOS's RedwoodAudio.driver HAL plug-in (phone/audio),
  `/dev/redwood-haptic` -> DRV2624 level follower (0914), VirtualAudio.plugin moved back from
  /Library/Audio/Plug-Ins/HAL.disabled, and the MobileGestalt cache rebuilt (CacheVersion made stale once).
- **Audio DSP boots** (0915-0917, r14c, `adsp=1`): HackiOS's redwood_adsp.c with lito's DSP memory
  (0x89200000, 40 MB); TrustZone authenticates Android's /vendor/firmware/adsp.* (in /private/var/local/fw),
  up in 38 ms, GLINK (IPCRTR, apr_audio_svc), QRTR node 5 with 11 services, APR audio services up.
  Our side must make GLINK items 478/479 itself (0917).
- **Blocker:** ~10 s later the DSP's sensor_process fails (`sar.cc: chre_utils fatal`) and takes the whole DSP
  down. Other Qualcomm ports: the sensor PD reads its config and registry through a FastRPC file service on
  the host (hexagonrpcd: /vendor/etc/sensors/config, /mnt/vendor/persist/sensors/registry). Next: a minimal
  FastRPC host (channel fastrpcglink-apps-dsp, adsp_listener + apps_std) serving those files, then the speaker
  path: QUIN_TDM_RX_0 (2 ch, S32_LE, 48 kHz) to two CS35L41 at 0x40/0x41 on SE9 (mixer_paths_noextcodec_snd.xml).
- Tooling: tools-claude/phone-agent.sh (WSL helper: boots, file server, SSH to the phone, logs); dropbear on
  the phone (key ~/.ssh/redfin-claude); builds published to branches builds-xnu / builds-userland.

## Flash, cameras, sensors (2026-10-24 evening, r15a-r16)

**Flash LED (0918, `sweettorch=2`): works.** PM8150L qpnp-flash-led-v2 (SPMI SID 5, 0xd300, APID 286, owned by
the APPS EE), channels 0+1 together (the rear LED, `led:switch_2`). At start the driver writes what
`qpnp_flash_led_init_settings()` writes for this DT (headroom auto mode off: it was 0x07; ISC/warm-up delays, ramp
rates, VPH droop), then torch mode with software strobe and no safety timer. Poke `t MA [MS]`
(`tools/flame-cmd.py 't 100 10000'`), sysctl `kern.sweet_torch` 0..1000. r16c: 100 mA per channel held for the
full 10 s, off on its timer. Limits: `sweettorch_ma` (100, cap 200; Android's torch is 300), `sweettorch_secs`
(120, cap 600), PM8150L temperature alarm (SID 4 0x2400) any stage = off.
- Learned the hard way: LED_STATUS2 bits 2:0 (OTST) are derating bands, not faults (r15a), and single-check
  LED-fault / open-short flags come and go while lit (Linux only logs them); only flags that persist for three
  checks (300 ms) count. Switching off is always allowed, even after the driver stopped (r15a's off writes were
  refused; the LED stayed lit at 50 mA until raw SPMI writes switched it off).

**Camera icon and flashlight button: not yet.** HackiOS shows Camera.app with `/arm-io/isp` (camera-rear/-front)
and Control Center's flashlight with `/product/camera` `flash` (`tools/mkadt.py --camera --flash` now writes both).
On this iOS 16.7.16 root either one, with the MobileGestalt cache rebuilt, leaves SpringBoard at the boot logo
(r15a both, r15b flash only, 5+ min; backboardd never presents). r15c (plain ADT, original cache) boots. iOS then
waits on mediaserverd's capture device, which does not exist: the flags have to come together with the
capture-device shim (HackiOS `camera_device.c` / `inject_media.c`; RedwoodAudio.driver already runs code in
mediaserverd and is the natural place). MobileGestalt caches: the r15a/r15b caches are kept next to the original as
`MobileGestalt.plist.r15a-camera` / `.r15b-flash` in
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches.

**Camera sensors (0919, `sweetcam=2`, needs `sweethaptic=1`): all three answer (r16g).** `tools/flame-cmd.py 'c N'`
powers sensor N up in its module file's order, reads the chip ID, powers it down: IMX355 0x0355, IMX481 0x0481,
IMX363 0x0363; every SLG51000 LDO reports VOUT_OK within 1 ms. From the live DT and Android's module files
(phone agent `twrp-pull-camera` -> recon/camera, decoded with `tools/redfin-camsensor.py`):

| # | Sensor | Bus (pins) | Slave (8-bit) | ID @0x0016 | Reset | MCLK | Power-up (module file) |
|---|---|---|---|---|---|---|---|
| 0 | rear IMX363 | CCI0 m0 (17/18) | 0x20 | 0x0363 | GPIO23 | MCLK0 GPIO13 | VIO LDO7 1.8, VANA LDO3 2.85, VAF (PM8150L GPIO8), VDIG LDO1 2.85, LDO4 1.8, LDO6 1.1, reset, MCLK 24 MHz +10 ms |
| 1 | rear ultra-wide IMX481 | CCI0 m1 (19/20) | 0x34 | 0x0481 | GPIO25 | MCLK1 GPIO14 | VIO, VANA LDO2 2.85, VDIG LDO5 1.1, MCLK, reset |
| 2 | front IMX355 | CCI1 m0 (27/28) | 0x34 | 0x0355 | GPIO21 | MCLK2 GPIO15 | VIO, PM8150L GPIO2, MCLK, reset +12 ms |

Rails: Dialog SLG51000 at I2C 0x75 on SE9 (the DRV2624's bus; cs PM8150L GPIO4, enables GPIO9/10 low, Google's
`slg51000_config_tuning()`); LDO n enable = MATRIX_CONF_A (0x110d) bit n-1, VSEL = (uV - base)/step within
MINV..MAXV, STATUS +0xc1 bit1 VOUT_OK / bit0 ILIM. MCLK from camcc RCG 0x5004/0x5024/0x5044 (branches
0x501c/0x503c/0x505c), XO 19.2 MHz for the probe (24 MHz needs camcc PLL2). camcc needs GCC camera AHB (0xb008,
enabled + HW-gated) and XO (0xb03c, found **off**; Linux keeps both on). Titan top GDSC camcc 0xc1c4, its clock 0xc1a0.
Chip ID read by bit-banged I2C on the CCI pins (HackiOS's way; no CCI block needed).
- **0920: XNU's I/O map was full.** r16a-r16e reset ~8 s after the camera driver's thread mapped ~600 KB with
  `ml_io_map()` (even with no register access at all, r16e); r16c without it ran on. The I/O submap is 8 MiB,
  KMA_NOFAIL, and SWEET drivers never unmap. 0920 makes it 32 MiB; 0919 maps only the pages it uses.

**Sensors (accel/gyro, light/proximity): behind the audio DSP.** /vendor/etc/sensors/config (recon/fw-adsp):
LSM6DSR accel+gyro on SSC I3C bus 1 (I2C 0x6a / I3C 0x0a, IRQ 113), TCS3701 light+proximity on SSC I2C 5 (0x39,
IRQ 111), LIS2MDL magnetometer SSC I2C 6 (0x1e), BMP380 pressure SSC I2C 5 (0x76). The SSC QUPs sit in LPASS:
an APPS access to an LPASS register is an external abort (HackiOS redwood_adsp.c), so there is no direct route.
Order of work: (1) keep the DSP's sensor PD alive: a FastRPC host file service (hexagonrpcd's apps_std/adsp_listener:
sensors/config, the registry, sns_reg.conf) over the `fastrpcglink-apps-dsp` channel, with buffers in the DSP's
SMMU context; (2) a QMI client for SNS (service 400) over our QRTR, SEE protobuf (postmarketOS libssc is the
reference); (3) iOS side: HID event services for accelerometer/gyro/ALS/proximity that backboardd/CoreMotion
accept (iPhone X normally gets them from the AOP/SPU). (1) is also what audio needs (the PD crash takes the whole
DSP down), so it comes first.

**Camera frames into memory (0921-0922, r17d-r17g): all three sensors.** HackiOS redwood_camera.c cam=3/4 with
lito's numbers, in `bsd/dev/sweet_cam.c`. Commands (sweetcam=2), each run on its own thread:
- `poke c 20`: the CSID-lite's test pattern, 1600x1200 RAW10 colour bars, one frame (r17d: correct bars).
- `poke c 21 SENSOR MODE OPTIONS`: the sensor's own frames. SENSOR 0 IMX363 / 1 IMX481 / 2 IMX355; MODE as
  `tools/redfin-camtab.py` lists them; OPTIONS hex: [3:0] sensor test pattern (2 = colour bars), [15:8] CSIPHY
  settle (0: module file's 14), [31:16] exposure lines, [47:32] analog gain code (0x0204), [55:48] frames.
  Working examples: `c 21 2 2 0x3c00a280000` (front, 1640x924), `c 21 0 10 0x1c00960_0000` (rear, 2016x1136),
  `c 21 1 3 0x3000708_0000` (ultra-wide, 2328x1310).
- `poke c 22 MS`: time before each stage (default 300), so a hang shows its stage in the ring.
- The run prints `files read /dev/pmem PA LEN`; fetch with the phone agent, decode with
  `tools/redfin-camraw.py FRAME W H OUT.png --cfa BGGR --stride S` (S = W*10/8 rounded up to 16).
- Tables: `tools/redfin-camtab.py MODULE.bin camera-<sensor>.tab` (vendor data, phone only) ->
  `/private/var/local/fw/camera-<sensor>.tab` (`files put`); read at run time.

The sequence: titan GDSC, camcc PLL0 (Lucid 1200 MHz) and the capture RCGs/branches at the DT's lowest levels,
GCC camera hf/sf AXI, an apps-SMMU match register (stream 0x800 mask 0x5e0) to a context bank with translation
off; camcc PLL2 (Zonda 960 MHz, aux /2) -> MCLK 24 MHz (M/N 1/20); refgen (0xff1080 bit 0, found off); the sensor
powered as for `c N`; tables init + resM (+ exposure, + tpgN); CSID-lite 0 RX from the PHY -> RDI 0; IFE-lite 0
WM0 frame mode; CSIPHY v1.2.2 = the 1.2 tables (D-PHY, 4 lanes, lane enable 0xd5, settle 14); stream on; frames;
WM stopped at the last; stream off; all back. Results: front IMX355 colour bars and a picture of the room; rear
IMX363 and IMX481 8 frames each at 30/60 fps (dark: the phone lay on its back), no ECC/CRC errors.

Lessons (each cost a reboot):
- r17a/b/c: the phone reset at `c 20` with nothing logged: 0921 mapped 128 KB of the SMMU and then read the context
  banks' SCTLRs at 512 KB and up. The whole 1 MB is mapped now.
- The UDP live log does not carry what a poke's run prints; the ring does: read it with `klog 0x101d0e710`
  (0922 kernels) while the run's stages wait (`c 22 MS`).
- No RPMh vote of ours: r17a's mx.lvl vote (SVS_L1, then 0 at the end) replaced the apps RSC's vote.
- The write master puts lines at 16-byte boundaries and wants the next frame's address each frame.
- One CSIPHY mapping per PHY (r17d/f set up the first PHY again for the second sensor: no packets).
- The SMMU bank's CBAR does not go back to 0 when written: the last run's bank is taken again.

Torch check (r17g): with the flash LED lit (`poke t 100 8000`) during `c 21 0 10` / `c 21 1 3`, the rear frames went
from black (mean 64, the black level) to mean 883 (IMX363) and 237 (IMX481, the lit desk visible): the rear sensors see.
Full-resolution modes also stream: IMX363 mode 0 4032x3024, IMX355 mode 0 3280x2464 (8 frames, no errors).

**/dev/redwood-camera (0923, r18a-r18b): works.** Boot-arg `sweetcamdev=1` (with `sweetcam=2`). HackiOS's cam=5 device
(header `phone/audio/redwood_camera.h`): a read gives a frame header and the RAW10 frame, writes give EXPOSURE (lines,
linear gain 256 = 1x, frame lines), SENSOR (1 back IMX363, 2 front IMX355, 3 ultra-wide IMX481; HackiOS numbering),
FOCUS (ignored: no lens motor driver yet). Sessions run from the first read to the last close on `stream_up()`, three
places of GPU-pool memory below 4 GB, the next address given at each RDI 0 SOF, the exposure in the sensor's group hold.
Mode: the most pixels at 4:3, <= 31 fps, <= 13 MP (IMX363 4032x3024, IMX355 3280x2464, IMX481 2328x1746);
`sweetcam_sensor=` / `sweetcam_mode=` choose the first. r18a's write-combined places copied at ~120 MB/s; r18b's are
cached and the frame's lines are invalidated first: 10 MB in ~3 ms, the front camera at its full 30 fps with HackiOS's
AE/AWB in `camera_test` (`phone /var/local/bin/camera_test raw 60 sensor 2`; picture in
/private/var/local/camera_test.nv12).

**iOS camera code in RedwoodAudio.driver (phone/audio, r18a+).** HackiOS's `inject_media.c`, `camera_device.c`,
`camera_isp.c` (MIT) are built into the HAL plug-in mediaserverd already loads (no injection). Adapted: the kernel's
sensor numbers, `kern.sweet_torch` for the torch, tuning files `/private/var/local/fw/camera-<sensor>.isp` (none yet:
identity colour matrix, no lens shading), front camera not turned; no iOS 16.5 address is trusted: methods are
replaced by class and selector, the Metal device list and FigFlashlight's callers are left alone, and without
`/dev/redwood-camera` nothing of the capture stack is touched. r18b: the plug-in loads, audio and haptics still work,
all eight methods are replaced (16.7.x addresses logged: `+[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor]` at
0x1a1f40c84 unslid, etc.). The old plug-in is kept on the PC in `backup-audio/` (`*.before-camera`).

**Camera.app (2026-10-25, r18c-r18e): the session starts and the first preview picture is given.** What it took:
- r18c: ADT with the camera (`mkadt.py --highmem --camera`, `adt-camonly.adt`) and a MobileGestalt cache made on it
  (the r18b one kept as `com.apple.MobileGestalt.plist.r18b`). Still no capture devices: mediaserverd never started its
  capture servers. MediaToolbox's `FigMediaServerStart` starts them (CMCaptureCore `FigStartCaptureServers`) only when
  `MediaToolbox.framework/<D22|D221|Default>/SubServerConfiguration.plist` has `StartRecorderServer` = true; ios-sweet's
  root set it false (the portrait-filter prewarm crash, which inject_media.c now no-ops). Set true on the phone (originals
  beside them as `SubServerConfiguration.plist.before-camera`; copies in the PC's `recon/mg/ssc-*`): AVFoundation lists
  "Back Camera" (16 formats) and "Front Camera" (18), and Camera.app opens with its full interface.
- 0924 (r18d): tccd's sandbox extension for kTCCServiceCamera could not be issued (the Sandbox stand-in returned ENOENT),
  which Camera.app takes for a refusal: AVCaptureDeviceInput -11852 "Cannot use Back Camera". Extensions are issued now.
- 0925 (r18e): mediaserverd died at every session start in VideoToolbox's FigGetAlignmentForIOSurfaceOutputToDisplayService
  (`-[__NSCFNumber objectForKey:]`): AppleCLCD's DisplayPipePlaneBaseAlignment is a dictionary on an iPhone.
- 0926 (r18e): /dev/redwood-camera tries a sensor start again (r18d gave the device up for the boot after one PMIC GPIO
  read-back of 0 during mediaserverd's restarts).
- RedwoodAudio.driver (r18e-user): -[BWMultiFilterThumbnailNode prepareForCurrentConfigurationToBecomeLive] wrote
  through its Metal filter renderer's NULL `filterDescriptor` (no Metal device in mediaserverd) right after
  "PrimaryScaler: the first picture given (1504x1128 420f)": the node is made ready as a plain BWNode and renders nothing
  (no filter thumbnails). Installed; not yet seen with Camera.app in the foreground (below).
- Tools: `imgdump imp ADDR` names the Objective-C method holding an address (a2s only has `<redacted>` in CMCapture);
  `tools/dis.sh FILE ADDR` disassembles `imgdump read` dumps.

Stopped there because the battery ran down (13% at boot to 5%, -640 mA with Camera.app streaming on USB power): the
phone was sent to fastboot mode to charge. Camera.app was also behind alerts it cannot get past without a tap
(location services, then "Low Battery"), which make it inactive, so its session does not run.

**Next for the cameras:**
1. Charged, boot r18e, dismiss the alerts once (Cancel on the location one), open Camera: the preview should show the
   back camera (no colour tuning yet: identity matrix). Check mediaserverd stays up (`klog`, `CRASH` lines), then a
   photograph, the front camera, video.
2. The vendor starts each stream as it is reserved, so a session's set-up switches sensors 3-4 times (~0.35 s each);
   starting the worker only when the graph is configured would make opening the camera quicker. The SMMU reports a
   fault (FSR 0x400) when a stream is stopped mid-frame: harmless so far, worth a look.
3. Colour tuning: the `com.qti.tuned.*` files of /vendor/lib64/camera -> `camera-<sensor>.isp`.
4. The IMX363's lens motor (actuator on CCI0) for FOCUS; the flashlight button through the stream's TorchLevel.

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
