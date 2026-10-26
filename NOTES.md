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
- 0910 no set/way D-cache clean on every idle WFI (sailfish 0180: idle CPU 133% -> 22%); AppleKeyStore
  says no passcode (lock state 0x6, sls 3) so coreduetd stops polling it; AKS logs 5 lines per selector.
- 0911 GIC SPIs for SWEET drivers (sailfish 0181: `sweet_spi_attach`, dispatched from sleh_irq); sec_ts on
  its attention interrupt (TLMM gpio9 -> summary SPI 208 = INTID 240) with a polling fallback;
  `sectouchirq=0` polls as before.
- 0912 vibration for iOS: sysctl `kern.sweet_haptic` (ms | strength << 16) queues a pulse;
  `sweetui=1` inserts /var/local/lib/SweetHaptics.dylib (phone/haptics) into SpringBoard and apps,
  mapping UIKit feedback generators and the vibrate sound onto it; `sweetenv=` from sailfish 0104/0163.
- 0913 network privileges from the iOS Sandbox's entitlement map (socket delegation, network statistics,
  NECP, global proc info) for the kernel, platform binaries and entitled processes. r11 showed WebKit
  networking, nsurlsessiond, trustd and mDNSResponder denied PRIV_NET_PRIVILEGED_SOCKET_DELEGATE, which
  makes necp_client_add refuse every connection they open for an app.
- 0914 `/dev/redwood-audio` + `/dev/redwood-haptic`, the kernel ends of HackiOS's RedwoodAudio.driver
  (phone/audio, MIT): iOS plays its haptics as waveforms on the Actuator audio device once the ADT has
  /product/haptics closed-loop (tools/mkadt.py now copies it from the D22 tree); each write's peak drives
  the DRV2624 (`sweet_haptic_drive`). Speaker frames are dropped until the ADSP path exists. Install the
  plug-in with tools/redfin-install-audio.sh; SweetHaptics.dylib (`sweetui=1`) is no longer needed.
  Works (r13c): the root also needs /Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin back (sweet's image
  moved it to HAL.disabled; without a device it crashed mediaserverd) and a fresh MobileGestalt cache
  (it keeps "no haptics" from the first boot).
- 0915 the audio DSP (`adsp=1`, `adsp_step=N`): HackiOS's redwood_adsp.c with lito's DSP memory
  (0x89200000, 40 MB); firmware in /private/var/local/fw (Android's /vendor/firmware/adsp.*).
- 0918 flash LED as a flashlight (`sweettorch=1` look, `=2` usable, `=3` blink at 5 mA when ready): PM8150L
  qpnp-flash-led-v2 (SPMI SID 5, 0xd300) channels 0+1, torch mode as leds-qpnp-flash-v2.c; poke `t MA [MS]`,
  sysctl `kern.sweet_torch` 0..1000; <= `sweettorch_ma` (100, cap 200) per channel, <= `sweettorch_secs` (120).
- 0919 camera sensors (`sweetcam=1` look, `=2` poke `c N` probes sensor N, `=3` all three at boot): rear IMX363
  (CCI0 m0, 0x20), ultra-wide IMX481 (CCI0 m1, 0x34), front IMX355 (CCI1 m0, 0x34) powered up in their module files'
  order (SLG51000 LDOs over SE9 at 0x75 with Google's tuning, PM8150L GPIO 2/8, reset GPIO 23/25/21, MCLK from camcc
  at 19.2 MHz, titan top GDSC), chip ID register 0x0016 read by bit-banged I2C on the CCI pins. Needs sweethaptic=1.
- 0920 XNU's I/O map (osfmk/arm/io_map.c) 8 -> 32 MiB: ml_io_map() is KMA_NOFAIL and SWEET drivers never unmap;
  ~600 KB more (0919's first version) and every boot reset a few seconds later (r16a-r16e).
- 0921 camera capture, step 1 ("poke c 20", sweetcam=2): camcc PLL0 + Titan RCGs/branches, GCC camera AXI, mx.lvl
  vote, apps-SMMU bypass context bank for the IFE streams, CSID-lite test pattern -> IFE-lite RDI0 -> write master 0
  into a GPU-pool buffer (1600x1200 RAW10). HackiOS redwood_camera.c's sequence with lito's clocks; all undone after.
- 0922 camera capture, step 2 ("poke c 21 SENSOR MODE OPTIONS"): camcc PLL2 for the 24 MHz MCLK, the sensor's tables
  from /private/var/local/fw/camera-<sensor>.tab (tools/redfin-camtab.py; vendor data, phone only), CSIPHY v1.2.2
  D-PHY, CSID-lite RX -> RDI0 -> IFE-lite WM0. c 20/21 run on their own thread (pokes run on the thread that sends
  the log: r17a/r17b's c 20 went down with nothing logged).
- 0923 /dev/redwood-camera (sweetcamdev=1 with sweetcam=2): HackiOS cam=5's device for its camera_device.c in
  mediaserverd: frame header + RAW10 per read, EXPOSURE/SENSOR/FOCUS writes; sessions on stream_up(), three GPU-pool
  places, next address at each RDI0 SOF; sensors 1 back IMX363, 2 front IMX355, 3 ultra-wide IMX481; linear gain.
- 0924 Sandbox stand-in: extension issue (op 5) writes a token into libsystem_sandbox's buffer, consume (op 6) gives
  handle 1. tccd took the old ENOENT for a refusal: Camera.app's AVCaptureDeviceInput failed -11852, black preview.
  Also needed on the phone: MediaToolbox SubServerConfiguration.plist StartRecorderServer=true (capture servers).
- 0925 AppleCLCD DisplayPipePlaneBaseAlignment as { PlaneBaseAlignmentLinear = 64 } (a dictionary, as on an iPhone):
  VideoToolbox's FigGetAlignmentForIOSurfaceOutputToDisplayService took the number for one and mediaserverd died
  ("-[__NSCFNumber objectForKey:]") each time Camera.app's capture session started.
- 0926 /dev/redwood-camera: PMIC GPIO writes tried three times; a session whose sensor did not start is tried again
  (three failures in a row before EIO for the boot). r18d gave the device up after one gpio8 read-back of 0.
- 0927 IOSurface lock result: a plane's bytes per row also at +0x10 of its entry, where IOSurface.framework (16.7)
  reads it. Bi-planar surfaces had 0 bytes per row per plane: green photographs, black camera preview, VT -12902.
- 0928 SweetAccelerator: every refused v2 call logged (first 40 per client), refused imports/maps with details.
- 0929 the rear camera's lens: the IMX363 module's AF motor is driven by its OIS controller, an ON Semi LC898129
  (module file: actuator/OIS/EEPROM "lc898129dp", slave 0x3b, 16-bit registers, 32-bit data; live DT actuator@0/ois@0 on
  CCI 0 master 0 with VAF): status 0xF100 polled, servos on (0xF010 <- 7), position 0xF01A <- 0x20000 | code (codes
  400..725 for 0..1023 until the per-unit calibration is read; `sweetcam_af_inf`/`_mac`, `sweetcam_af=none|NAME`);
  FOCUS works, frames carry `focus` and LENS_MOVING; parked before VAF goes off. (0930 is kept for the calibration.)
- 0931 /dev/redwood-camera exposure contract: EXPOSURE.d digital gain (0x020e.., 256 = 1x), reserved[3] its range,
  reserved[4] fps x 1000; group hold from the "holdon"/"holdoff" tables; margin/black/analog cap from the table file's
  new "info" table (tools/redfin-camtab.py; old files keep 40/64/8x-16x); frames report the clamped values.
- 0932 /dev/redwood-camera modes: SENSOR.c class (auto/photo, video 16:9 >= 30 fps, video60) when b is ~0; the same
  sensor+mode again is a no-op, another mode of the streaming sensor switches without a power cycle, MODE_CHANGED on the
  first frame after; a failed select keeps the previous sensor; table files read once ("c 23" forgets them).
- 0933 flash for camera frames: sweet_torch_flash() with the PM8150L module's safety timer (<= 300 mA/channel,
  <= 100 ms; pre-flash at torch current <= 500 ms); FLASH lights at the SOF before the frame, off after its end,
  FLASH_LIT on the lit frames; SOF time in reserved[1]/[2].
- 0934 /dev/redwood-camera stop/fault hygiene: halt at a frame boundary, SMMU fault only for FSR & 0x800001fe, the
  write master's next place never read, read() waits <= 1 s (EAGAIN at close/SENSOR), 100 ms start debounce, 300 ms
  close linger.
- 0940 IOSurface rows: 0159's 64-byte rounding also for a one-plane surface given with plane info and for every plane of
  a planar surface (a plane whose rows grew is moved past the one before it; first 16 logged `SWEET SURF: 0940`):
  `sweetsurfplanar=0` leaves planes as asked, `sweetsurfalign=0` all of it. For Turnip's explicit layouts (pitchalign 6).
- 0941 render server GPU resilience: a GPU reset caused by another process's job is not reported to backboardd/SpringBoard
  (their device stays; the hung job's pid is logged; `sweetgpuspare=0` as before), their refused imports are tried again
  (4 x, 2-16 ms), refusals log both prepare() results.
- 0942 the `present:` line per 300-frame window: window ms and presents/s, per-frame clean/blit, put off / flips / late in
  the window, mode (single buffer / flip) and `sweetgpufreq`, totals in brackets.
- 0943 `SWEET FB: 5s: swaps N shown N dropped N | le11 a le18 b le26 c le35 d gt35 e | p50 X.X p95 Y.Y ms | blitq Q us fence F us | hz H` (always); `sweetfbx=` 0x1 TimingElements/SyncRate + GetBlock(0x40) + sel 77, 0x2 no dcache clean unless the surface's seed moved; `sweetfb_hz=90` = DCS 0x53 0x38 + 11.1 ms ticks; poke `p fc`, `p hz 60|90 [tc]`.
- 0944 `sweetfbx` 0x4 (off by default, needs the present thread): present at SwapEnd (2-deep queue, SwapEnd held <= 50 ms when full, put-off presents retried every 1 ms, landed 0905 flips flushed at once) and vsync ticks phased 0.5 ms after INTF1's TE (tear-check frame/line counters; `SWEET FB: tick phased:` x3, free-running if the counter stops).
- 0945 touch stats (always): `SWEET SECTS: 5s: events N (moves M, batched B) rate R/s | dt p50/p95/max ms | gaps>20ms G | irq->dispatch p50/p95 us | wake p50/p95 us | per drain avg A max B (C us max) | x X` (sample time = attention IRQ) and `SWEET HID: real|swipe: moves N dt p5/p50/p95/max ms | gaps>20ms G | dispatch avg/max us` (HID timestamps iOS gets; 5 s or at lift after >= 10 moves). `sectouchx=` 0x1 HID timestamp = IRQ time + one move per finger per drain, 0x2 READ_ALL_EVENT for >= 3 queued, 0x4 read-only probe of 0x30/0x34, 0x8 touch thread priority 92.
- 0950 ADSP FastRPC (WS-D): sweet_adsp.c answers `fastrpcglink-apps-dsp` (64 x 0x64 intents) and `glink_ssr`;
  `/dev/redwood-fastrpc` (0600, one opener) carries 40-byte messages / 16-32-byte answers for phone/fastrpc/fastrpcd;
  ioctls FASTRPC_SMMU_IDENTITY (SID 0x1403-5 -> apps SMMU bank with translation off, logged `SWEET FASTRPC: SMMU:`)
  and FASTRPC_ALLOC (RAM < 4 GiB from the GPU pool, zeroed, 32 buffers kept; `SWEET FASTRPC: N bytes for the DSP at PA
  (GPU pool ...)`); `adsp=2` starts the DSP on the first open of the device (fastrpcd up first); `adsp_sleep=1` Android's other APPS SMP2P
  entries ("sleepstate" = 1, "rdbg" = 0); `adsp_qlog=1` IPCRTR datagrams/intents logged (`SWEET QLOG:`); `adsp_fastrpc=0` old way, `=2` log every message; poke `f 0` status, `f 1` DSP
  words + last words, `f 2` QRTR services/ports, `f 3 SID` identity, `f 5` SMMU faults (`f 9` help).
- 0951 pd-mapper (QMI 0x40, port 0x4001) in the ADSP's kernel QRTR: msm/adsp/{root,sensor,audio}_pd + avs/audio,
  instance 74; announced after the DSP's HELLO and to its lookups; PD failure reports logged (`SWEET PDMAP:`);
  `adsp_pdm=0` off; poke `f 4` announces again.
- 0956 `/dev/redwood-qrtr` (qol-plan 3.1): one QRTR port (0x5000+n) per open, {node, port, data} datagrams, ioctl
  QRTR_LOOKUP, DEL_CLIENT on close; sysctl `kern.sweet_adsp_services` ("svc:inst@node:port,...").
- 0952 speakers' path through the ADSP (`bsd/dev/sweet_sound.c`, HackiOS redwood_sound.c's APR layouts): `sound=1` LPASS
  core votes (AFE 0x100f4 blocks 3/4), LPI gpio6-9 func2, QUIN TDM clock 0x208 6.144 MHz + port 0x9040 (4 x 32-bit slots,
  mask 0x3; no group, as Android); `sound=2` + SMMU stream 0x1401 identity bank, ADM/ASM session 1, -30 dBFS tone with the
  amps off, path left up; `sndsecs` `sndlpi=0`; poke `a status|tone [MS]`. Default off.
- 0953 the two CS35L41 amps (`sweet_cs35l41.c`, SE9 via sweet_se9_xfer, ASP bypass, OTP trims, gain 17) + HackiOS guard
  (`sweet_guard.c`): `sound=3` tone audible at <= -20 dB vs Android, amps only while playing (off after 2 s);
  `sndbelow`, `sndgpio=1` (PMIC GPIO resets: PM8150L GPIO11 left, PM7250B GPIO11 right; allow-listed SPMI writes);
  poke `a gain DB|off|on`.
- 0954 `/dev/redwood-audio` -> ring -> ASM (`sound=4`): `redwood_audio_set_sink()`/`redwood_audio_volume()` in
  sweet_audio.c, iOS volume added to `sndbelow`, `sndgain` (guard gain, default 12 dB), amps gated after 2 s of silence.
- 0955 microphones (`sweet_mic.c`, `mic=1`): ALC5513 (rt5514, plain TDM mode) on SE7 0x57, reset TLMM 91, PRI TDM TLMM
  49-52, AFE 0x9001 (8 x 32, mask 1), ADM record + ASM session 2 reads, `/dev/redwood-mic` per the plug-in ABI;
  `micgain`; poke `a mic SECS` -> `SWEET MIC: files read /dev/pmem PA LEN`.
- 0960 TSENS temperatures (bsd/dev/sweet_thermal.c, read only): `SWEET THERMAL:` every 5 s (silver = hottest A55,
  gold = sensors 9/11, prime = 10/12, cpuss, gpu, ddr, camera, npu, aoss), sysctl `kern.sweet_temp_*` (deci-degC);
  once at 20 s the PM7250B charger/QG/SDAM registers (`SWEET BATTERY: boot regs ...` + decoded FCC/FV/JEITA/WD line);
  SPMI read allow-list + 0x15/0x16/0xb1. `sweettherm=0` off.
- 0961 cpufreq readback: tables parsed the Linux way (`~` skip, `*` boost rows), the old boot selection kept for
  `flamecpufreq=0/1/N`; `SWEET CPUFREQ: busy ...` every 5 s (per-CPU busy % from recount idle time via
  sched_prim.c `sweet_cpu_idle_abs()`, perf-state readback, cycle-counter MHz, LMh ceiling); command server
  `w stat|freq DOM IDX|table|gov|chg` (sweet_poke.c hands "w WORD" to sweet_power_cmd; "w ADDR VAL" unchanged).
- 0962 `sweetbig=2`: foreground threads try CPU6 (gold) first, CPU7 (prime) only while CPU6 is busy (1 = old order,
  default). tools/mkadt.py: redfin clock values (1804.8/2208/2400 MHz); cluster-type stays 0 (no AMP in this kernel).
- 0963 DVFS governor, `flamecpufreq=2` (default 1 = pinned max as before): 30 ms per-domain tick, util = busiest CPU of
  the domain, target = cur * util / 80 % (x2 at >= 95 %), lowest valid row above it; up at once, down after 3 ticks;
  silver floor 1.1 GHz; perf-state writes only. `w gov 0|1 [MS]`; `w freq` takes a domain out until `w gov 1`.
- 0964 thermal caps (sweet_thermal.c, 1 s sampling): hot = max(gold, prime, cpuss, camera); level 1 > 75 C (gold/prime
  <= 1.8 GHz), 2 > 85 C (gold/prime 1.2, silver 1.5 GHz, GPU level 2), 3 > 100 C (gold/prime lowest row, silver 1.0 GHz,
  GPU 1), each released 10 C lower, logged once per change. `sweettcap` bit 0 CPU (default 1), bit 1 GPU (runtime GMU
  HFI perf vote via sweet_gpu_level_cap()/a6_perf_vote(), off by default), 0 = log only. `w cap N|auto`, `w gpu N`.
- 0965 PSCI idle, `sweetidle=1` (default off): CPUs 1-7 call PSCI CPU_SUSPEND 0x40000003 (lpm "pc"; never the
  notify-rpm cluster states) instead of WFI when the next timer is beyond 1774/2207 us; resume via resume_idle_cpu ->
  arm_init_idle_cpu + sweet_idle_resume() (GIC ICC regs, timer re-arm). Broadcast wake = arm,armv7-timer-mem frame 0
  (0x17c21000, SPI 8 on CPU0) armed at the earliest sleeper deadline minus exit latency, IPIs the sleepers. Probes
  PSCI_FEATURES first; a PSCI error turns it off. `SWEET IDLE:` at boot; counters in the `SWEET CPUFREQ:` line.
- 0966 battery: 4000 mAh, 5 s poll, SOC seeded from QG SDAM 0xb147 (if 0xb146 valid and within 15 % of the voltage
  estimate) then coulomb-counted from QG LAST_ADC_I with a 0.2 %/poll pull to the voltage estimate at |I| < 100 mA;
  1 %/poll slew; IsCharging = I > +50 mA; Temperature from the JEITA zone (0x100d). `SWEET BATTERY: SOC seeded ...`.
- 0967 SPMI write path (sweet_spmi_write): APID channel EXT_WRITEL (Linux pmic-arb v5), owner EE 0 checked, only SID 2
  0x1061/0x1070/0x1341/0x1342/0x1365/0x1366/0x1370, read back + `SWEET CHG: write ...`; nothing unless `sweetchg=1`.
  `w chg wr ADDR VAL`.
- 0968 charger policy (bsd/dev/sweet_charger.c, every 5 s after the 20 s register dump): DCP/CDP/Rp1.5 -> 1500 mA,
  Rp3.0 -> 2000 mA ICL in HC mode (0x1370, 0x1366.0=1, 0x1342.0=0, 0x1365.4=1), FCC 2000 mA (1000 when JEITA soft or
  SMB die over bound), FV lowered to 4.45 V only if higher; SDP/float left to the hardware; dry run unless `sweetchg=1`;
  `sweetchgpol=0` off; <= 200 writes/boot. `w chg` (decoded state), `w chg apsd`, `w chg pol 0|1`.
- 0969 USB `ud_thread`: 10 ms polls after 200 quiet 1 ms polls (no event, no TX in flight), 1 ms again on the next event;
  `sweetudpoll=1` = always 1 ms.
- 0971 sensor HID services `SweetHIDAccel/Gyro/ALS/Prox/Compass/Pressure/Orientation` (SweetHID.cpp; usage pairs 0xff00/3,
  9, 4, 8, 0xa from IOHIDFamily-1035.70.7's AppleHIDUsageTables.h, filled in; pressure 0x20/0x31, orientation 0x20/0x8a
  with DeviceOrientationUsage 0x64 + UIDeviceOrientation, which locationd's CLOrientationNotifier matches/accepts):
  every open, user client (pid), copyEvent type and setProperties key/value logged `SWEET MOTION:`, ReportInterval kept;
  `sweetmotion=MASK` (default 0x77 = all but prox, which crash-looped backboardd; 0x7f all;
  0x100 = Transport "SPU"; 0x200 = neutral copyEvent answers on every service; ALS and prox always give one);
  user-space property reads logged.
- 0972 `/dev/redwood-motion` (sensd's samples, qol-plan §3.3; read() = status, ioctl MOTION_GET_WANT) and `poke m`
  (`m fake accel|gyro|als|prox|compass|pressure|orient [V..]`, `m rot N`, `m stop|secs|status|log|knob|knobs`):
  bsd/dev/sweet_motion.c.
- 0980 Bluetooth probe logging (`sweetbtlog=1`, off by default): every kernel-control `CTLIOCGINFO` name, every failing
  open() of /dev bt*/uart*/cu.*/*bluetooth* nodes (`SWEET BTLOG:`, 300 each), and the sweetiolog IOKit trace (`IOK name:`,
  1000 lines) on bluetoothd, BlueTool, wirelessproxd, bluetoothuserd, BTLEServer.
- 0981 /dev/btuart (`btuart=1`, no node by default): WCN3998 HCI UART on QUP0 SE5 (0x894000, SPI 606 via 0911) for
  phone/bt/btd: GENI FIFO mode, RTS/CTS, 16 KiB RX ring, baud/flow/drain/flush/timeout/stats ioctls; ENXIO without
  XBL-loaded UART firmware; `btuartos=16|32`; poke `b 0` state, `b 1` HCI version, `b 2` QCA EDL version.
- (no patch) `phone/fastrpc/fastrpcd` (WS-D, GPL-3.0+, hexagonrpcd port): attaches to the ADSP sensors PD over
  `/dev/redwood-fastrpc` (buffers FASTRPC_ALLOC + /dev/pmem, Android adsprpc layout, session 3) and serves its
  apps_std file calls from `/private/var/local/hexagon` (tools/redfin-install-hexagon-wsl.sh); launchd job
  `org.iosonpixel.fastrpcd`, log `/var/local/fastrpcd.log`, exit 3 when the DSP goes; `-v`, `--mmap-method 2|4`.
- 0957 poke `a gain N` (or `-N`): N dB under Android's level; hard cap 6 dB under (ASP bypass, no protection firmware)
  for sound=3 and 4, also for `sndbelow`.
- 0982 stand-in Bluetooth nubs (`sweetbtnub=1` "bluetooth", `=2` "marconi-bt", `=3` both; off by default): SweetBTNub
  services under the platform expert for bluetoothd's IONameMatch notifications; every property read from them logged
  with found/MISSING, user-client requests refused + logged, setProperties keys logged (`SWEET BTNUB:`).
- 0973 AppleARMBacklight publishes the panel's nits for CoreBrightness (MinNits/MaxNits/MaxNitsPanel,
  HardwareAccessibleMin/MaxNits, user-accessible-max-nits, digital-dimming-min-nits, brightness-nits(-cap),
  DisplayPanel/ProductLuminanceMin/Mid/Max: 2..500, integer nits; 500 nits <-> level 1023): `sweetnits=0` off.
  `tools/mkadt.py --backlight` (opt-in) also copies D22AP's /backlight node with max-nit-value/LmaxProduct = 500.
