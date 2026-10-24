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
