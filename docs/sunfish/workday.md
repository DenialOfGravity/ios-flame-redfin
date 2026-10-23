# Workday log — Fri 2026-10-23

## Summary (written 09:58; nothing left that can be done without you)
- **Done:** battery smoothing (0128); CPU render path 4.3 → 17.2 fps (dropped vmd/ReportCrash/axassetsd);
  sleep/wake 11/11 OK; remote `key` command (0137); GMU boots on A618 (0129–0133).
- **Partial:** GPU: clocks, GDSCs, GMU boot, rails OK; HFI fault decoded to fw pc 0x19a8 (first SMMU read).
- **Blocked:** GPU HFI (SMMU path / gpu_memnoc_gfx clock, see gpu-notes.md); Wi-Fi join (fw assert at vdev start).
- **Deferred (not cheap):** brightness (DSI DCS), sensors/rotate (SLPI), vibration (Taptic stack).
- **Needs you tonight:** 1) does the OLED go dark on "display off"? 2) battery % looks sane? 3) nothing else.
- Phone: k14 (no GPU) with flamereboot=600 → parks in fastboot (charges there). 0 kernel panics in soak.

## [06:40] Step 0 preflight — pass (with a battery warning)
- **Battery patch 0128 (k10) works:** shown % tracks the estimate and steps 1% at a time in the
  direction of the measured current: 35% → 34% → 32% at −169…−289 mA. No 100% flash since boot.
- **Battery warning:** the phone *drains* on this USB port while iOS runs (~−200 mA, ≈1% per 5 min).
  At 32% (06:39) it reaches the 10% gate around 08:30–09:00. Mitigation: keep the phone in fastboot
  between test boots (iOS not running) and keep boots short.
- **`flamereboot=0`:** read `iokit/Kernel/arm/SweetPlatformExpert.cpp`: `reboot_s <= 0` pets the
  watchdog forever → no timed return to fastboot (watchdog stays armed, so a real hang still resets).
  Not used for test boots.
- **Baseline:** idle `SWEET FB: 5s: 50 swaps (10.0 fps), avg copy ~2.7 ms`; boot animation ~24 fps.
  Screenshot logs/shots/baseline-0640.png.
- **Soak:** `port/tools/sunfish-soak.sh` → logs/soak.log every 60 s.

## [06:42] GPU M1 recon — pass
- docs/gpu-notes.md: A618 chip id 0x06010800; GPU 0x5000000, GPUCC 0x5090000, SMMU 0x5040000; GDSC offsets
  same as A640; GCC ddrss_gpu_axi 0x4452c (A640 0x71154); zap region 0x98f95000, a615_zap; PDC TCS3 cmd1
  data 2 (A640 3); HFI path depends on GMU fw HFI major (v1 → v1 DCVS table + TEST msg; quirk hfi-use-reg).
- Phone parked in fastboot between tests: battery **rises** there (3788 → 3822 mV in 10 min).

## [06:50] GPU M2/M3 constants (patch 0129) — fail (log silent), diagnosed partially
- 0129: A618 constants, fw names (a618_gmu, a615_zap), freq table at/below A640 per level, PDC fix.
  Firmware passed via `GPUFW=… sunfish-boot.sh` (mkpayload --gpufw → /chosen/gpufw,*).
- k11 (`sweetgpu=1 sweetgpufreq=2`): phone boots, SSH works, **but the USB live log is silent from boot**.
  Control k11b (same kernel, no sweetgpu): log flows (3165 lines / 75 s). → GPU bring-up wedges the console
  (likely a CPU stalled on an unclocked/unpowered register while holding the console lock).
- Next (0130): GPU log mirrored into RAM at 0xE2000000 (read via /dev/pmem) + `sweetgpudelay` so bring-up
  starts after USB/SSH are up.

## [07:20] GPU M3 power/clocks — pass; M4 GMU firmware — fail → fixed in 0131
- 0130: GPU log RAM trail (0xE2000000) + `sweetgpudelay`; also fixed **RSCC hardcoded at flame's
  0x02c6a000+0x23000** (on SM7150 an unclocked block → that was the k11 console stall).
- k12 trail: `cx gdsc -> on`, gpucc ahb/cxo/cx_gmu on, GMU regs read (`init_result 0, rpmh_state f`),
  SMMU bank programmed. Then `gmu fw: bad block f1f00060` — a618_gmu.bin is a **legacy raw ITCM image**
  (kgsl `_load_legacy_gmu_fw` for a630/a615 family), not flame's block format.
- 0131: raw ITCM load, chip id 0x06010800 in GMU_SFR_ADDR (was 0x06040100), legacy HFI queue ids
  (cmd 0, msg 4, dbg 5), legacy OOB (set BIT16 / ack BIT24). Still to do: HFI v1 tables if needed.

## [07:35] GPU M4 GMU boot — **pass** (0131)
- k13 trail: `gmu: 1 firmware blocks loaded` → `gmu: init result babeface BOOTED`.
- Then every A640-style HFI message timed out (`hfi status 0`). kgsl for non-A640: `GMU_HFI_CTRL_INIT=1`
  (0x1f986) + poll status, `H2F_MSG_INIT`, v1 perf table, BW table, `H2F_MSG_TEST`, DCVS via
  `GMU_DCVS_*` registers + OOB 7. cmd-db on sunfish: MC0 0x50000, SH0 0x5003c, ACV 0x5000c (= flame's DDR
  BW entries), CN0 0x500a8 (flame's CNOC entries 0x50034/0x5007c/0x5004c don't exist here).
- 0132 implements that sequence.

## [07:45] GPU M4b HFI — fail → 0133
- k14 (0132): `hfi: ctrl init -> status 0 TIMEOUT`; every message unacked; G2H_INFO 0x800000 =
  **bit 23 HFI_IRQ_CM3_FAULT**: the GMU CPU faults right after boot.
- Differences vs kgsl's legacy start found: SFR chip id must be packed (`0x06018000`, I wrote 0x06010800);
  `a6xx_gmu_gfx_rail_on` (OOB 6, GX/MX vote idx) and `a6xx_gmu_sptprac_enable` (0x778000 → poll bit 3)
  run before HFI start on a615-family. 0133 adds all three.

## [07:55] GPU 0133 — partial pass (rails), HFI still faulting → 0134
- k15: `legacy: gfx rail (gx idx 3 mx idx 2) acked, sptprac on`, G2H clean after boot, **GX GDSC on**
  (f8222000). The CM3 fault (bit 23) now appears right at `HFI_CTRL_INIT`.
- Then OOB gpu_set timeout and CP `me_init` TIMEOUT (hwfault c0000) → phone wedged, watchdog put it back
  in fastboot (safety net works).
- Cause candidate: our HFI queue table — 3 queues, size in **bytes**; kgsl: 4 queues (dispatch disabled),
  size in **dwords**. 0134 fixes it for A618.

## [08:30] GPU M4b HFI — **BLOCKED** (3-attempt rule); switching to fallback
- 0134 (4-queue table) and 0135 (HFI at 0x60001000): same CM3 fault at HFI_CTRL_INIT.
- 0136 diagnostic: GMU SMMU FSR 0x400 (no fault bits), FAR 0 → internal CM3 fault, not a page fault.
- Blocker + exact next steps written in docs/gpu-notes.md (A618 RPMh/PDC sequences, GMU crash dump).
- Safety: every failed GPU boot wedged after CP init and the watchdog returned the phone to fastboot.
- Next: fallback = CPU render path (start: `sweetfb_hz` 30 → 60).

## [08:50] Fallback: CPU render path — **pass: 4.3 → 17.2 fps** (4×)
- New `port/tools/sunfish-fpsbench.sh TAG SECS`: unlock + scripted home-page swipes, averages the
  `SWEET FB: 5s` fps lines. Same workload for every measurement.
| Change | Swipe fps |
|---|---|
| baseline `sweetfb_hz=30` | 4.3 |
| `sweetfb_hz=60` | 4.9 |
| drop `com.apple.voicemail.vmd` (Visual Voicemail, spun ~1 core without cellular) | **16.7** |
| drop `com.apple.ReportCrash` (was busy with TTS-synth crash reports) | **17.2** |
- Jobs removed with new `port/tools/sunfish-launchd-drop.sh LABEL…` (backup on phone:
  /System/Library/xpc/launchd.plist.pre-drop). `sweetfb_hz=60` is now the helper default.
- Remaining CPU in the bench: backboardd (~1.1 cores) = the actual renderer.

## [09:00] Step 2 cheap items — triage (GPU blocked early, so started ahead of 11:30)
- **Brightness — deferred (not cheap).** sunfish panel sofef01 is OLED with `bl_ctrl_dcs`: brightness is a
  DSI DCS 0x51 command. The kernel has no DSI code; it needs the DSI controller's command-DMA path
  (Linux dsi_ctrl_hw_cmn kickoff) while ABL's autorefresh runs. A mistake can freeze the display.
- **Auto-rotate / sensors — deferred (not cheap).** Accelerometer etc. are behind the SLPI sensor DSP:
  needs SLPI boot (PAS like the modem) + QMI sensor service + an iOS motion HID.
- **Vibration — deferred (not cheap).** PM6150 vibrator @0x5300 (SID 1) is easy to drive, but iOS
  haptics go through Apple's Taptic stack (AppleHaptics/HID), which would also need emulating.
- **Sleep/wake stability — doing it.** New command `key N [MS]` (0137) lets the test press power remotely.

## [09:00] Step 2.4 sleep/wake stability — **pass** (0137)
- `flame-cmd.py key 0 150` (new, 0137) presses power remotely. 11 toggles over 5 min: every press →
  `SWEET HID: key 0x30` → `SWEET FB: display off/on`; SSH alive in every state; 0 panics.
  Screenshots logs/shots/sleep-1.png (wallpaper) / wake-1.png (black) — labels swapped (first press slept).
- **Needs you tonight:** does the OLED actually go dark when "display off"? We only stop presenting
  frames; real panel-off/brightness needs a DSI DCS command (same missing piece as brightness).

## [09:15] Extra: TTS synthesizer crash loop — **fixed**
- SiriTTSSynthesizerAU / MacinTalkAUSP / KonaSynthesizer aborted ~once a minute (12× each per 6 min).
  Requester found with `oslog`: **axassetsd** (accessibility assets → TTS voice queries). Dropped
  `com.apple.accessibility.axassetsd`. After: 0 TTS crashes in 2 min; swipe bench 16.9 fps (noise vs 17.2).
- Soak so far: 0 kernel panics today; battery 35–36% (fastboot charging between boots keeps it up).

## [09:10] GPU blocker next-step #1 — eliminated (no code change)
- RSCC/PDC/TCS programming matches kgsl's A618 path word-for-word → not the cause. Details in
  docs/gpu-notes.md. GPU stays blocked; next real step = GMU TCM dump + CM3 fault decode (multi-hour).
- Using the free slot to start Step 3 (Wi-Fi join, 1 h cap) early.

## [09:40] Step 3 Wi-Fi join — **BLOCKED** (3 attempts), scan + Settings list still OK
Every join: WLAN fw asserts at `vdev start` (first TX/channel setup), `EX:wlan_process … WLAN RT:0x1084/0x1089
PC=0xb01ab7b0`, then modem ERR-FATAL. Same PC in every variant tried today:
1. rails as Google's icnss driver: order cx-mx, 1.8-xo, 1.3-rfa, **ch1 before ch0**, 3.3 V at **3312 mV** (was 3304) — same crash.
2. cx-mx **752 mV** (icnss default; DT says 640) via new `/var/local/wlan-rails.conf` override — same crash.
3. **WMI_PDEV_SET_REGDOMAIN** (tag 0x51, cmd 0x4001; fw eeprom code is 0) + channels 1–11 / 36–48 no
   longer marked passive (they were all passive) — same crash.
Previously ruled out: BDF variants, channel TLV encoding, missing TFTP files.
Left (not tried): firmware HL3.2.2 vs flame's 3.2.0 — try a WLAN.HL.3.2.0 wlanmdsp.mbn (flame's), or
compare our WMI sequence (INIT resource config, PDEV params before vdev start) with ath10k's for wcn3990.
Join tests used the temporary /var/local/wlan.conf, deleted after each test (verified absent).
After a clean reboot: 3 scans, 14 networks, no modem crash, Settings > Wi-Fi lists Gansekoele/Johann
(logs/shots/wifi-0940.png).

## [09:45] GPU blocker: CM3 fault decoded — **root cause narrowed** (0138 diag)
- 0138 copies GMU DTCM/ITCM to low RAM after the fault. k20 died before the console flushed (watchdog → fastboot,
  no hard hang); a warm boot of k14 (k21) read the copy back from 0xE2010000.
- Exception frame: **pc 0x19a8, lr 0x227f, r3 0x60001000**. In a618_gmu.bin that is the first read of the HFI
  queue table → bus fault. The GMU can't reach its HFI memory through the SMMU.
- Our SMR readback is 0 on every sunfish boot (flame: 84000005) → GMU stream 5 likely unmatched.
- Details: docs/gpu-notes.md. Next: 0139 logs global SMMU fault + all SMR/S2CR (diagnostic, k22).

## [09:55] GPU — **BLOCKED, parked** (3 diagnostic boots on the HFI fault)
- 0139 (SMMU global-state diag, k22): the phone reset ~2 min after boot, before the diag lines flushed; no data.
  It returned to fastboot by itself (no hard hang).
- Best lead for next time: `gcc gpu_memnoc_gfx … (still halted)`. That is the GPU SMMU's clock per the DT, which fits
  "SMR readback 0" + "GMU bus fault on first SMMU read". Exact next steps are in docs/gpu-notes.md.
- Phone: k23 (k14, no GPU) running with flamereboot=600 → returns to fastboot to charge. Battery 3806 mV at 09:48.

## [10:20] GPU — **PASS: Adreno 618 composites the UI** (0140 + 0141)
- 0140: kgsl SMMU `attach-impl-defs` written; SMMU state logged at setup: impl regs stick, SMR/S2CR read 0.
  The hypervisor emulates the SMMU global space (Google arm-smmu.c comment) and dropped our SMRs.
- 0141: **SMR mask 0** (DT `#iommu-cells = 1` = exact SIDs; flame's mask 0x400 was refused). SMR now `80000005`,
  `hfi: ctrl init -> status 1 ok`, CP `me_init` executes (rptr = wptr, idle), zap ok, **"GPU ready in 5979 ms"**.
- Framebuffer switched to GPU present by itself ("frames now scaled to fit by the GPU, panel stride 4352").
  Screenshot logs/shots/gpu-k25-home.png (read with `flame-shot --stride 4352`).
- Swipe bench: **20.1 fps** (CPU path 17.2). GPU present ~27 ms/frame → GPU clock probably at minimum:
  HFI messages after INIT still CM3-fault (`info 800000`), so DCVS (clock up) times out. Next: that fault.
