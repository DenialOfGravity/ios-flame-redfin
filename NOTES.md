# iOS on Pixel 4 (flame) - working notes

Port of [ios-sweet](https://github.com/dipa-studio/ios-sweet) (XNU xnu-8796 + iPhone X iOS 16.7.16 userland on
a Redmi Note 10 Pro, SM7150) to the Pixel 4 (`flame`, SM8150). Read `docs/ios-sweet/NOTES.md`
for the history of ios-sweet's kernel patches (0001-0081); this file records what differs on flame.

What works now is in [README.md](README.md). [HANDOFF.md](HANDOFF.md) is the engineering log, newest
first: every boot, what broke and why. Paths under `work/`, `logs/`, `backup/`, `dtb/`, `stock/`,
`downloads/`, `images/` and `research/` in either file are local and not in git (see the README).

## Test loop (no buttons, no screen)

1. Phone in fastboot (`adb reboot bootloader` from TWRP).
2. `fastboot boot shim/out/shim-boot.img` (shim alone = probe; with a payload = XNU).
3. The shim sets the PM8150 PON reason to bootloader, so a reset lands in fastboot.
4. `fastboot boot downloads/twrp/twrp-3.7.1_12-0-flame.img`, then
   `tools/flame-log-pull.sh shim logs/X.txt` (and `xnu` for the XNU ring).
- `boot_a` holds TWRP (flashed 2026-10-19) so any reset without the PON reason boots TWRP
  (adb root), not Android. `boot_b` is stock. Restore everything with `images/.../flash-all.sh`.
- macOS asks "Allow accessory to connect?" the first time a new USB identity appears; until
  then `ioreg -p IOUSB` shows the phone `!registered`.

## Google ABL boot image rules (found the hard way)

`fastboot boot` fails with "Error verifying the received boot.img: ..." unless:
- the kernel is **LZ4 (frame) compressed** (uncompressed -> `Unsupported`),
- the Image header has **text_offset 0x80000** (0 -> `Invalid Parameter`),
- the image has an **AVB hash footer** (unsigned, algorithm NONE, padded to 64 MiB),
  `avbtool add_hash_footer --partition_size 67108864 --partition_name boot`.
Header v2, base 0, kernel 0x8000, ramdisk 0x1000000, tags 0x100, dtb 0x1f00000, page 4096,
stock `dtb` (two SM8150 base DTBs; ABL picks v2 and applies dtbo idx 11).
ABL loads the kernel at 0x80080000, the DTB at 0x84500000, the ramdisk at 0x84700000
(TWRP's 30 MB ramdisk went to 0xc0000000). max-download-size 256 MiB.

## Hardware facts (live FDT `dtb/live.dtb` + shim probe)

| | flame | (sweet) |
|---|---|---|
| CPU | 4x A55 (cpu0-3) + 3x A76 + 1x A76 prime, MPIDR 0x81000n00, MIDR 0x51df805e | 6+2 |
| RAM | <0x80000000 0x3cc00000>, <0xc0000000 0x140000000> (6 GB) | |
| GIC | GIC-600, GICD 0x17a00000, GICR 0x17a60000 stride 0x20000 | same |
| Timer | 19.2 MHz, vtimer INTID 19 | same |
| PSCI | 1.1 smc; CPU_ON, SYSTEM_RESET yes; RESET2, SYSTEM_SUSPEND no | |
| UFS | UFSHCI 3.0 @0x1d84000, LUN0 sda, userdata sda15 first 4K LBA 0x25e000, 0xc80ffb blocks | 2.1, same addr |
| Display | NT37280 cmd-mode DSC panel 1080x2280; ABL fb 0x9c400000 stride 4320 a8r8g8b8; CTL0, VIG0+VIG1 (540 each), LM0/1, DSC0/1, INTF1; **ABL enables INTF1 autorefresh** | video mode, 0x9c000000 1080x2400 |
| Touch | ST FTS (ftm5) on GENI SPI @0x890000 CS0, irq GPIO122, reset GPIO127, vdd L14A 1.8V, avdd L17A | Goodix I2C |
| Keys | power KPDPWR + vol- RESIN on PM8150 PON (SID0 0x800); vol+ PM8150 GPIO6 (SID0 0xc500), active low | vol+ PM6150L GPIO2 |
| PMIC arb | v5 @0xc440000, chnls 0xc600000, obs 0xe600000, cnfg 0xc40a000, EE 0, 512 APIDs | same |
| Reboot reason | PM8150 PON SOFT_RB_SPARE 0x88f bits [7:1] = 2 (bootloader) -> fastboot; Linux clears it to 0 before every reset; 0x10 (= WDT) at boot | IMEM ignored |
| Watchdog | APSS WDT 0x17c10000, 32765 Hz, ABL leaves it off; bite register 20 bits (~32 s max) | |
| USB | DWC3 @0xa600000, SNPS femto HS PHY 0x88e2000, QMP SS PHY 0x88e8000 | QUSB2 |
| ramoops | 0xa47ff000 (2 MB), alt 0xa49ff000 (TWRP /dev/access-ramoops) | |

DRAM partly survives resets (shim saw TWRP's kernel pointers at 0x100000000), but a marker
written to the alt ramoops region via /dev/access-ramoops did not survive reboot -> bootloader -> TWRP.

## Layout

- `shim/` flame shim (`build.sh`, Homebrew llvm + lld), `tools/` host tools, `phone/` code that runs in
  iOS on the phone (each directory has a `build.sh`; they use `work/userland/bin/ios-cc`)
- `xnu/patches/` ios-sweet 0001-0081 + flame patches from 0082
- `work/dxb/` blacktop darwin-xnu-build checkout; `work/dxb/xnu` is a git repo whose HEAD is
  "baseline + applied patches", new patches come from `git diff`
- Not for git: `backup/` (partition dumps, serials), `dtb/`, `stock/`, `downloads/` (TWRP,
  IPSW parts, AOSP tools), `work/`, `logs/`

## Flame patches

- 0082 IORPC.kernelContent: Xcode 16+ iig emits it; field added (kernel only) and set at the
  two user->kernel IOUserServer dispatch sites, as in newer XNU.
- 0083 flame basics: early console on the 0x9c400000 / 2280-row framebuffer (SWEET.h
  constants used by start.s, sweet_early.c, arm_vm_init.c), vol+ on PM8150 GPIO6, the Redmi
  touch driver off by default (sweettouch=1 forces it; it would vote L11C to 3.2 V), APSS
  watchdog keepalive in SweetPlatformExpert (flamewdt=0 off, flamereboot=N stop after N s).
- 0084 early framebuffer block mapped Device-GRE, not Normal-NC (no speculative reads into pil_slpi).
- 0085 ST FTS touch (ftm5) over GENI SPI; 0086 its HW clock gating + cpufreq for all 8 cores.
- 0087 fixed-rate vsync + fps stats. 0088 flame USB offsets.
- 0089 log timestamps, RAM mirror of the console ring, poke scripts; with 0090: USB through the apps SMMU
  the way ABL does it (own context bank, translation off) and the UDP command server.
- 0091 USB ARP fixes, TCP file server, `sync` command (0092-0093 included).
- 0094 /dev/pmem (physical memory and SCM calls for userland drivers), file server READ.
- 0095 the A640 core in the kernel, GPU present (frames scaled to fit by the GPU).
- 0096 SweetAccelerator (IOAcceleratorES for Metal, `sweetmtl=1`); 0097 its user client.
- 0098 panic logs into the persistent log ring. 0099 PM8150 RTC time of day (`sweetrtcoff`).
- 0100 clonefile copy fallback on HFS, tap/swipe commands (0101 included).
- 0102 RPMh ARC/VRM votes from userland (PMEM_RPMH). 0103 AMFI stand-in answers trust cache queries.
- 0104 planar IOSurfaces report summed bytes-per-row/element (blank Safari pages).
- 0105-0109 GPU: VA reuse, more page tables, perf vote (`sweetgpufreq`), recovery, async submit.
- 0110-0112 Apple continuous display corners (final: 0112, GPU scissored bands + CPU row masks).
- 0113 wait for a client's last fence before unmapping its memory.
- 0114 the AMFI policy answers dyld's policy query: @rpath frameworks of third-party apps load.
- 0115 v2 GPU user client (NativeAdreno ABI) for Turnip: GPU buffers from RAM XNU does not manage
  (no cacheable physmap alias), multi-IB submits, progress-based hang detection.
- 0116 `sweetmtl=2` selects SweetMetal2 (metal2vulkan + Turnip). 0117-0118 pool accounting, submit timing.
- 0119 present not waited for. 0120 per-process GPU stats, BCM (bus/DDR) votes over PMEM_RPMH.
- 0121 vsync notifications carry the refresh period (CA's frame deadlines were always past).
- 0122 DDR + memory NoC voted up at GPU start (`sweetddr`), GPU pool caps (`sweetgpucap`, `sweetgpureserve`).
- 0123 en0 + Apple80211 for wifid (ios-topaz 0900 + 0128, from HackiOS), the station over /dev/wlan to
  wland in userland.
- 0124 10-bit surfaces as BGRA only for WebContent (`sweetsurf10`); the joined network keeps its scan record.

## Redfin patches

Pixel 5 (`redfin`, SM7250 lito) on top of the sunfish series; plan and hardware map in
[docs/redfin/port-plan.md](docs/redfin/port-plan.md). Numbered 09xx (were 0150-0152 until
2026-10-24) so upstream's next sunfish patches (0150, 0151, ...) never share a number; they apply after
all upstream patches. Kernels "0151"/"0152" in the logs = 0901/0902.

- 0900 redfin basics: early framebuffer 0xa0000000 (SWEET.h), vol+ PM8150L GPIO5 (0xc400, SID 4),
  USB femto HS PHY at 0x088e3000 with the redfin param-override-seq, battery/charger reads on PM7250B
  (SID 2) and the SPMI read allowlist for it (RTC stays on SID 0).
- 0901 sec_ts touch (`bsd/dev/sweet_sects.c`, `sectouch=1`): Samsung S6SY79x on GENI SPI SE0 (0x880000),
  mode 3, TX-only/RX-only framing as sec_ts.c; L17A 3304 mV allowed in sweet_rpmh; RPMh cmd-db falls
  back to lito's fixed region 0x80860000; flame's FTS driver now off by default (its TLMM address is
  the GPU on lito).
- 0902 USB on lito: GCC USB clock offsets from gcc-lito.c (sleep 0xf018, utmi 0xf01c, cfg-noc 0xf07c,
  aggre 0xf080, aux 0xf054, clkref 0x8c010), DWC3 SMMU stream `USB_SID` 0xe0 (was 0x140); cpufreq-hw prime
  cluster 0x18327800 (boost = fewer cores than the cluster, as Linux); battery label PM7250B.
- 0903 upstream sunfish 0151's QUSB2 v2 init off by default (`sweetqusb=1` to force): redfin's HS PHY is
  the femto at 0x088e3000 and 0x088e2000 is its EUD register. Upstream 0150 (GPU pool skips wland's
  rmtfs buffer at 0xe1000000) applies to redfin unchanged: same pool range, same rmtfs address.
- 0904 Adreno 620 (`A6_GPU_ID` 620 in sweet_a6xx.h; 618/640 keep their values): lito addresses (GPU
  0x3d00000, GPUCC 0x3d90000, SMMU 0x3da0000, RSCC 0x3de0000), A650-family GMU (kgsl gmu_vma: DTCM at
  0x10004000, cache memory from a650_gmu.bin's PREALLOC_REQ blocks), RSC/PDC with cmd-db addresses,
  HFI v2 with 275/400/500/625 MHz and lito's BCMs, A620 hw_init (512 KB GMEM, UBWC 3 hbb 14, APRIV,
  a650_sqe.fw), a620_zap into 0x8bc15400, Mesa FD620 values for the present blit, Turnip device info
  0x06020000. GPU buffer pool skips kregistry_mem 0xc8000000 and the 0xe2000000 log trail.
- 0905 double-buffered GPU present (`sweetfbflip=1`, off by default): blit into the buffer not on screen
  (second one at 0xa0a00000 in the splash region), flip VIG0+VIG1 once the fence lands, never write the
  old buffer before the flip latched (as ios-sailfish 0164).
- 0906 panel brightness: DCS 0x51 (10-bit, 0x4..0x3ff) through DSI0's command DMA (0x0ae94000), packet at
  0xa2200000 in the splash region, sent from its own thread between autorefresh frames (topaz 0104/0107);
  CoreBrightness via IOMFBBrightnessLevel, plus AppleARMBacklight with `sweetbl=1` (digital dimming then
  runs too: opt-in while CA renders on the CPU). `sweetbl_dcs=0` disables it.
- 0907 DRV2624 vibration motor (`sweethaptic=1`; `=2` buzzes once when ready): I2C 0x5a on GENI SE9
  (0x98c000, sweet_touch.c's FIFO code), enable line PM7250B GPIO1 via the APPS SPMI channel, SE9 clocks
  and pins gpio46/47. `tools/flame-cmd.py 'v 200'` buzzes 200 ms. Not hooked to iOS yet.
- 0909 haptics: skip the halt check of the hardware-gated wrapper 1 s_ahb branch (r9 stopped there).
- 0908 a620 zap shader into 1 MB-aligned memory (b02's p_align; r8 failed PAS mem setup at 0x8bc15400 with
  0xffcfffba after GMU, HFI, GX and ME_INIT had all worked): `sweetzappa=PA`, 0xc8100000, then the DT region.
