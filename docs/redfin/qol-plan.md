# redfin: quality-of-life plan — audio, power/thermal, charging, Bluetooth, sensors (2026-10-26)

Coordinator: Fable (this chat). Workers: Opus agents, one per workstream, code + CI only in phase 1; Fable merges,
builds images and runs the phone. Camera/GPU work (`claude/redfin-camera-gpu-plan.md`) is **on hold**; its branches
`ws-a/b/c-*` and `redfin-int` @ e9b2521 are the base. Read `redfin-automation-and-status.md` first for the device and
build flow; this doc is the work plan on top of it. Written after four read-only audits of `redfin-int`, the live DT
(`recon/live.dtb`), the r19 klog and the r14c live log.

## 0. Where things stand (audit facts)

| Area | State today | Evidence |
|---|---|---|
| **CPU** | All three cpufreq-hw domains written **once** to their top LUT row and left there: silver 1804, gold 2208, prime 2400 MHz. No governor, no readback. Idle = plain WFI (`SweetCPU.cpp` registers no `processor_idle`), no PSCI CPU_SUSPEND, so cores/clusters never power-collapse. Patch 0147 (`sweetbig=1`) sends every thread ≥ FOREGROUND to **CPU7 (prime) first**. `mkadt.py` marks all cores `cluster-type 0` with flame's clock values. 1 kHz pollers: USB `ud_thread` (1 ms), camera IFE loop (1 ms), touch fallback (8 ms). | `sweet_cpufreq.c:48,90`, `cpu.c:571`, `sched_prim.c:5056-5080`, `mkadt.py:191-198`, r19 klog `SWEET CPUFREQ` |
| **Thermal** | **No temperature is read anywhere.** Battery publishes a fixed 25.0 °C. thermalmonitord runs with no sensors. Hardware LMh may or may not be active (unknown). | `SweetBattery.cpp:135` |
| **Battery** | PM7250B read through the SPMI **observer** only ("observer reads only"); SoC is a voltage/OCV estimate with a 150 mΩ IR model and a generic curve, capacity hard-coded **5020 mAh (sweet's; redfin is 4000)**, 1 %/30 s slew; `charging` = "plugged in and charger state 1-4" so iOS shows the bolt while the battery net-drains. Never reads APSD/ICL/FCC, **never writes the charger**. | `SweetBattery.cpp:196-279`, 0062/0128/0900, r19 klog `SWEET BATTERY` |
| **Audio** | Plug-in side is complete: RedwoodAudio.driver presents Speaker/Actuator/Codec(mic); `/dev/redwood-audio` takes S16LE 2 ch 48 kHz and **drops the frames**; the plug-in already opens `/dev/redwood-mic` (S16 mono, non-blocking) which **does not exist**. ADSP boots (`adsp=1`), APR audio services up in ~5 s, then `err_qdi.c:1045:EF:sensor_process … sar.cc:27:chre_utils fatal` takes the whole DSP down ~10 s later. The DSP looked for **0** of our QRTR services first. | 0914-0917, `phone/audio/audio_plugin.c`, r14c live log |
| **Sensors** | LSM6DSR (accel+gyro), TCS3701 (ALS+prox), LIS2MDL, BMP380 are on the ADSP sensors PD's own buses (SSC I3C/I2C inside LPASS; lito has no SLPI). Only route: QMI SNS service 400 over QRTR to node 5. The ADSP QRTR lives **in the kernel** (`sweet_adsp.c`, `qrtr_input()` drops datagrams to local ports: "nobody here listens"); wland's userland QRTR drives the *modem* edge and cannot be reused for node 5. iOS side: every input already goes through kernel IOHIDEventService stand-ins (0058 `SweetHIDButtons`/`SweetHIDTouch`, backboardd opens `esuc`); the sensor event factories are compiled in. Verified event types: ALS 12, Accel 13, Prox 14, Gyro 20, Compass 21, Pressure 31, Orientation 10. | 0058, 0901, 0915, live.dts (adsp edge channels IPCRTR, apr_audio_svc, fastrpcglink-apps-dsp, glink_ssr; adsprpc cb10-12 SIDs 0x1403-0x1405) |
| **Bluetooth** | Nothing done; no Android-phone iOS port has tried. Hardware is clear from the live DT: WCN3998 HCI on **QUP0 SE5 @0x894000** (GPIO38-41 func qup05, GIC SPI 606, wake byte 0xfd), rails smpa4 / ldoc2 / ldoc10 / ldoa14 (the last three already voted by wland for WLAN), SW_CTRL TLMM 73 input, **no bt_en GPIO** (power-on pulse 0xFC over the UART), firmware `/vendor/firmware/crbtfw32.tlv` + `crnv32.bin`. iOS side: BlueTool/bluetoothd historically open `com.apple.uart.bluetooth` via a **kernel-control socket** plus `/dev/btwake` etc., then do Broadcom-specific init (patchram, 0xFC18 baud, …). Whether iOS 16 on D22 still works that way, and whether a non-Broadcom controller gets past init, is **unknown**. | live.dts:581,12433; LightBulbOne BlueTool write-up |

**The one gate:** audio playback, microphone and all four sensors all need the DSP to stay up, and the DSP dies because
its sensors PD cannot read its files. That is the FastRPC file service (hexagonrpcd's `apps_std`/`adsp_listener` over
`fastrpcglink-apps-dsp`). It is workstream **D** below and is on the critical path for A and S.

## 1. Targets (what "done" means)

- **Power:** phone idles cool; sustained Camera/Safari use stays below the A76 cap; `SWEET THERMAL` lines every 5 s;
  clocks follow load (prime/gold ramp, silver floor); battery % is real (gauge-seeded coulomb count, 4000 mAh),
  updates every 5-10 s, "charging" only when net current is positive.
- **Charging:** on a DCP/Type-C 1.5-3 A charger the phone **gains** charge while on and idle, and holds level with the
  camera running; ICL/FCC programmed from APSD/Rp with conservative caps (FCC ≤ 2 A, FV ≤ 4.45 V), derated when hot.
- **Audio:** the DSP survives indefinitely with `adsp=1`; iOS sounds and music come out of the speakers at a safe,
  limited level (software guard first, Halo protection firmware later); Voice Memos records from the mics.
- **Sensors:** autorotation (accel), raw gyro to apps, auto-brightness responds to the ALS, proximity reported;
  compass/pressure if free. CoreMotion `deviceMotion` fusion is a stretch goal.
- **Bluetooth:** stage 1 = raw HCI to the chip works (LE scan sees advertisements); stage 2 = a one-boot spike that
  tells us what bluetoothd needs; stage 3 = integration only if the spike says it is realistic.

## 2. Coordination rules

- **Base:** `redfin-qol` @ 0ac14e9 (= `redfin-int` e9b2521 + a CI change). Each workstream branches `ws-<x>` from it,
  **never pushes to `redfin-qol`**; Fable merges. Branch names below.
- **CI:** `gh workflow run xnu.yml|userland.yml -R DenialOfGravity/ios-flame-redfin --ref ws-<x>`. The CI change on
  `redfin-qol` publishes every run **also** to `builds-xnu-<branch>` / `builds-userland-<branch>`
  (and `builds-xnu-log-<branch>` on failure), so parallel workstreams no longer clobber each other: **fetch your own
  branch** and check `BUILD.txt` names your commit. Kernel build ≈ 10 min.
- **Kernel patch numbers (hard allocation):** D 0950-0951 + 0956; A 0952-0955, 0957-0959; P 0960-0969;
  S 0970-0979; B 0980-0989. One line per patch in `NOTES.md` ("Redfin patches"); patches made the CI way (pristine
  xnu-8796.141.3 + dxb patches + 0900…; `git apply --check` each) — the status doc "Build and image flow" says how.
  New `bsd/dev` files need a `bsd/conf/files` hunk (see 0914/0915).
- **File ownership (to keep merges trivial):** D owns `bsd/dev/sweet_adsp.c` and `phone/fastrpc/`; A owns new
  `sweet_sound.c`, `sweet_cs35l41.c`, `sweet_mic.c` and `bsd/dev/sweet_audio.c` (0914); P owns `sweet_cpufreq.c`,
  `SweetBattery.cpp`, `sweet_spmi.c`, `SweetCPU.cpp`, the 0147 hunk in `sched_prim.c`, `tools/mkadt.py` cluster
  values, and new `sweet_thermal.c`; S owns the 0058 HID files (`SweetHID.cpp` additions) and `phone/sensors/`;
  B owns `phone/bt/` and new `sweet_geniuart.c`. Nobody touches `sweet_cam.c`/`sweet_torch.c`/`phone/audio/camera_*`
  (camera chat) or `phone/metal2`. `sweet_poke.c`/`sweet_usb.c` command server: add commands under **one** new
  letter per workstream (D `f`, A `a`, P `w`, S `m`, B `b`) to avoid conflicts; P's 1 kHz-poller change to
  `sweet_usb.c` is the one exception and goes in last.
- **Shared ABIs are fixed here** (section 3) so S can build against D's device before it exists, and A against D's.
- **Rules from `AGENTS.md`:** RAM-only `fastboot boot`; never flash firmware partitions; vendor/Google/Qualcomm/Apple
  files never in git (served files go to `/private/var/local/hexagon/` on the phone, copies stay in `recon/`); no
  RPMh votes on the apps RSC unless the only voter (BT: do not drop wland's votes, add to them).
- **Phone:** one resource, Fable only, serially, after CI is green. Workers never queue phone-agent requests.
  Every image is `rNN` with a `.sha256` + `rNN.cmdline` in the project folder; the klog PA is re-derived per kernel.
  Reboot-risky steps (PSCI suspend, SPMI writes, amp enable) each get their own image with a kill-switch boot-arg.

## 3. Shared ABI contracts

### 3.1 `/dev/redwood-qrtr` (D implements in 0956; S consumes)
```
open()            -> one QRTR port on node 1 (ours), allocated by the kernel; O_NONBLOCK honoured
ioctl QRTR_LOOKUP (_IOWR('q',1,struct {u32 service; u32 instance; u32 node; u32 port;}))
                   : fills node/port from the kernel's qrtr_servers[] (service 400 = SNS; 0 = none yet)
write(): struct { u32 node; u32 port; u8 data[]; }   one datagram
read():  struct { u32 node; u32 port; u8 data[]; }   one datagram or EAGAIN; ≤ 64 KiB queue per port
Also a sysctl kern.sweet_adsp_services (string): "svc:inst@node:port,..." for `sensd --list`.
```
### 3.2 `/dev/redwood-fastrpc` (D, 0950; used by `fastrpcd` only)
```
write(): one struct fastrpc_msg {s32 client_id; s32 tid; u64 ctx; u32 handle; u32 sc; u64 addr; u64 size;} (40 B)
read():  one struct fastrpc_invoke_rsp {u64 ctx; s32 retval;} or EAGAIN
ioctl FASTRPC_SMMU_IDENTITY(_IOW('f',1,struct{u32 sid;})) : give SID 0x1403-0x1405 a context bank with
         translation off (the 0921 / radio.c smmu_wlan_identity pattern), so IOVA == PA; buffers come from
         /dev/pmem PMEM_ALLOC and MUST be below 4 GiB (refuse otherwise).
While the device is open the kernel keeps the channel open; close() = channel closed.
```
### 3.3 `/dev/redwood-motion` (S, 0972) — what `sensd` writes, what the HID stand-ins post
```
struct motion_sample { u32 type; u32 flags; u64 ts_mach; float v[4]; }
type: 13 accel (m/s², x y z), 20 gyro (rad/s), 12 als (lux, [1]=colour temp or 0), 14 prox (v[0]=1 near/0 far,
      v[1]=raw), 21 compass (µT), 31 pressure (kPa), 10 orientation (v[0]=UIDeviceOrientation 1-4)
```
### 3.4 Audio sink/mic (A keeps the existing plug-in ABI unchanged)
`/dev/redwood-audio` S16LE 2 ch 48 kHz frames (0914), `/dev/redwood-mic` S16 mono 48 kHz non-blocking reads,
volume ioctl `_IOW('r',1,{u32 below_eighth_dB; u32 muted})`. No plug-in change needed.

## 4. Workstreams

### WS-D — DSP keep-alive: FastRPC file service + QRTR ports (branch `ws-d-fastrpc`, Opus) — **critical path**
D0 **(S)** Confirm from r14c logs what the DSP opens: channels `fastrpcglink-apps-dsp` (left unanswered today),
   whether it ever looks up servreg/pd-mapper (log said 0 lookups). Document in the report.
D1 **(M)** 0950 `sweet_adsp.c`: open `fastrpcglink-apps-dsp` on the lpass edge (intents 0x64×0x40 as the DT), pass
   messages through `/dev/redwood-fastrpc` (3.2), SMMU identity ioctl for SIDs 0x1403-5 (apps SMMU 0x15000000, the
   0921/radio.c way; log the SMR/S2CR/CBAR used), `adsp_fastrpc=0` kill switch. Keep the DSP's SSR/"last words" logging.
D2 **(S)** 0951 pd-mapper in the kernel QRTR: serve servreg locator (service 0x40) for `msm/adsp/{root,sensor,audio}_pd`
   and `avs/audio` (ios-topaz's list; wland's `pdmapper.c` is the shape). Cheap insurance against (d) below.
D3 **(S)** 0956 `/dev/redwood-qrtr` per 3.1 (routing in `qrtr_input()`, port table, lookup from `qrtr_servers[]`).
D4 **(L)** `phone/fastrpc/fastrpcd`: port hexagonrpcd (GPL-3+: keep it a separate program, note in CREDITS) —
   listener loop (`INIT_ATTACH_SNS` handle 1 m0 pd 2 → remotectl open "adsp_default_listener" → register →
   adsp_listener handle 3 `init2`/`next2`), localctl/apps_std (freopen 1, fflush 2, fclose 3, fread 4, fseek 9,
   fopen_with_env 19, opendir 26, closedir 27, readdir 28, mkdir 29, stat 31)/apps_mem (`request_map64` ADD_PAGES →
   INIT_MMAP), hexagonfs mapping `/vendor/etc/sensors/{config,sns_reg_config}`, `/mnt/vendor/persist/sensors/registry`
   (writable copy), `/vendor/etc/acdbdata`, `/sys/devices/soc0/*`, `/usr/lib/qcom/adsp` onto
   `/private/var/local/hexagon/...`; payload builder on `/dev/pmem` buffers (`phone/wifi/pmem.[ch]`), 128-B alignment,
   `ctx = idx<<4 | pd`, addresses `IOVA | session<<32`; launchd job like wland's. Build in `userland.yml`.
D5 **(S)** Tooling: `tools/redfin-install-hexagon-wsl.sh` (copies recon/fw-adsp/hexagon + persist/sensors into the
   root image or over `files put`), and a `klog` grep list for the integrator.
Exit test (Fable, phone): `adsp=1 adsp_fastrpc=1` + fastrpcd running → DSP alive > 10 min, `sensor_process` no fatal,
`kern.sweet_adsp_services` lists service 400. Risks: session-bit encoding with a translation-off bank; PMEM above 4 GiB;
adsprpc-mem may need a hyp-assign (TZ SMC) — if the DSP refuses our buffers, report before trying SMCs; serving the files
may not cure `sar.cc chre_utils fatal` (then: dump what it asked for and whether `/mnt/vendor/persist/sensors/registry`
was writable).

#### D4/D5 as built: `phone/fastrpc/fastrpcd` (WS-D2)
- Program: `fastrpcd [-v] [-r ROOT] [--mmap-method 2|4] [-d DEVICE]`, GPL-3.0+ (hexagonrpcd's listener/localctl/
  apps_mem/marshalling + new `transport.c`, `apps_std.c`, `fastrpcd.c`). Built by `phone/fastrpc/build.sh` in
  userland.yml (artefacts `fastrpcd`, `org.iosonpixel.fastrpcd.plist`, `fastrpcd-test.log`); host tests
  `sh phone/fastrpc/test.sh` (layout bytes for a 2-in/1-out call, a fake DSP: attach, remotectl, INIT_MMAP fallback,
  the listener with a >4 KiB request via get_in_bufs2, DSP loss; apps_std over a temp tree).
- Transport: one buffer per call from `FASTRPC_ALLOC` (size classes 64 KiB/1/4/16 MiB, reused, never freed), written
  and read through `/dev/pmem`; Android adsprpc layout (`40n + 388` metadata, buffers at 128 B, `pv` = PA, page
  `addr` = page PA | 3 << 32); message `addr` = PA | 3 << 32, `size` = used rounded to 4 KiB; `ctx = idx << 4 | pd`
  (idx 1-63), client 0 for handle 1 (INIT_ATTACH_SNS, INIT_MMAP), the pid otherwise; answer thread matches ctx bits
  4-9, honours rspv2 flags (early/complete). INIT_MMAP: method 4 (Linux, num 16) first, method 2 (Android 64-bit,
  num 1) if the DSP refuses, then that one for good.
- Files: DSP path -> ROOT + path after `/system/vendor` -> `/vendor`, `/mnt/vendor/persist` -> `/persist`; `..` and
  links cannot leave ROOT; writes only under `/persist` (registry). `fopen_with_env`: absolute names as they are,
  relative ones in `<dir>/adsp/<name>` then `<dir>/<name>` for `$ADSP_LIBRARY_PATH` = /usr/lib/qcom/adsp,
  /vendor/lib/rfsa/adsp, /vendor/dsp and `$ADSP_AVS_CFG_PATH` = /vendor/etc/acdbdata. apps_std methods 0-5, 8-12,
  15, 16, 19, 22-24, 26-33; anything else (and any undecodable request) gets an error answer, the loop goes on.
- Exit codes: 0 `/var/local/fastrpcd.off`, 1 error, 2 no tree (after 30 s), 3 DSP gone (ECONNRESET), 4 refused.
  Waits (1-30 s back-off) for `/dev/pmem`, `/dev/redwood-fastrpc` (ENOENT/EBUSY) and the channel (ENOTCONN).
- Install: `bash tools/redfin-install-hexagon-wsl.sh USERLAND.zip [recon/fw-adsp] [recon/persist/sensors]` (root
  image + launchd job; `--live` pushes to the running phone with flame-files.py; `--stage-only` to inspect).
  Understands recon/fw-adsp/hexagon laid out like the phone or like hexagonrpcd's -R dir; soc0.txt split per attribute.
- Log lines to look for in `/var/local/fastrpcd.log`: `/dev/redwood-fastrpc open; SMMU stream 0x1403 is session 3`,
  `INIT_ATTACH_SNS (pd 2, tgid N) -> 0`, `adsp_default_listener (handle 0x..) register -> 0`, `adsp_listener: init2
  ok`, then one line per `fopen_with_env(...)`/`fopen`/`stat`/`opendir`/`readdir`/`fwrite` with its result.

### WS-A — Speaker + microphone (branch `ws-a-audio`, Opus; phone test after WS-D)
A1 **(M)** 0952 `sweet_sound.c` from HackiOS `hakios.sound.c` (APR AFE/ADM/ASM; message layouts carry over):
   `AFE_CMD_REMOTE_LPASS_CORE_HW_VOTE_REQUEST` 0x100f4 blocks 3/4 first (this is what lets APPS touch LPASS/LPI
   registers), LPI GPIO 6-9 func2 (`lpi_pinctrl` @0x33c0000, 0x1000 stride) for QUIN TDM, AFE CLOCK_SET 12.288 MHz
   internal, GROUP_DEVICE 0x9140 + port **QUIN_TDM_RX_0 0x9040** (sync src 1, data delay 1, invert 0; **resolve the
   slot count**: DT 8×32-bit vs mixer 2 ch S32 — read `audio_platform_info.xml`/the redbull machine driver), SLOT_MAPPING,
   ADM DEVICE_OPEN_V5 + MATRIX_MAP, ASM SHARED_MEM_MAP (SMMU stream **0x1401**, IOVA pool 0x10000000, sid mask 0xf → bit 32)
   OPEN_WRITE_V3 PCM16 48 kHz, RUN, WRITE_V2 8×960-frame periods on WRITE_DONE. `sound=1` set up only, `sound=2` test tone
   into the DSP with amps off. HackiOS's "SM6375" comment in 0915 is wrong (SM7325): fix it.
A2 **(M/L)** 0953 `sweet_cs35l41.c`: two CS35L41 at I2C 0x40/0x41 on **i2c@98c000 (SE9, shared with the DRV2624 in
   0907 — reuse its bus code and lock)**, reset GPIO from the DT, ASP TDM slots 0/1, PCM source **ASP (bypass)**, small
   fixed digital gain, port `hakios.guard.c` (HPF, power averaging, limiter) in front of the sink; `sound=3` audible at
   -20 dB. Halo protection firmware (`cs35l41-dsp1-spk-prot.wmfw/.bin`, vendor, phone only) is a later step.
A3 **(S)** 0954 connect `/dev/redwood-audio` (0914) to the ASM stream: ring buffer, volume ioctl → ADM/ASM gain, amps
   gated off after 2 s of silence; `sound=4` = iOS plays.
A4 **(M)** 0955 `sweet_mic.c`: the mics are **three DMICs on a Realtek ALC5513 (rt5514)**, control I2C **0x57 on
   i2c@984000**, reset TLMM 91, audio over **PRI_TDM_TX_0 port 0x9001 group 0x9101** on APPS TLMM 49-52 (func pri_mi2s,
   8 mA) — no LPASS pins. rt5514 init + Android's mixer values (`Sto1 ADC MIXL DMIC Switch`, `Stereo1 DMIC Mux DMIC1`,
   ADC1 volume 23; 2nd/3rd mic at slot offsets 8/12), AFE port config, ADM record path, ASM OPEN_READ session 2 into a
   ring, `/dev/redwood-mic` per 3.4. `mic=1`.
A5 **(S)** NOTES/port-plan text, CREDITS (HackiOS APSL parts), a `sound_test`/`mic_test` run book.
Exit tests (Fable): `poke a tone` audible; Settings → Sounds plays; Voice Memos records and plays back; no DSP crash;
amp temperature/current sanity (guard logs).

### WS-P — Power, thermal, charging (branch `ws-p-power`, Opus; mostly independent, first to reach the phone)
P1 **(S)** 0960 `sweet_thermal.c`: TSENS read-only (tsens0 TM 0x0C263000: 0 aoss, 1-6 cpu0-5, 7-8 cpuss, 9-12 the four
   A76 sensors, 13-14 gpuss; tsens1 TM 0x0C265000: 3 ddr, 6 npu, 7 camera; status `TM+0xA0+4n`, bits 11:0 deci-°C signed,
   bit 21 valid, `TM+0xE4` bit 3 first round done). Log `SWEET THERMAL:` every 5 s, sysctl `kern.sweet_temp_*`. Also log
   **once at boot, read-only**, the SMB5/QG facts we need for P6-P7: 0x1366, 0x1107, 0x1108, 0x1061, 0x1070, 0x1090,
   0x1307, 0x1308, 0x1506, 0x1651, 0x1653, SDAM 0xB146-0xB148 (needs peripheral 0xB1 on the read allowlist), 0x48C6.
P2 **(S)** 0961 per-CPU busy % from idle time + perf-state readback + LMh readback (`limits-dcvs` 0x18358800/0x18350800)
   in the 5 s line; `poke w ...` command family for tests (`w freq DOMAIN IDX`, `w gov 0|1`, `w stat`).
P3 **(S)** 0962 scheduler: 0147 prefers **CPU6 then CPU7**, prime only when CPU6 is busy (boot-arg `sweetbig=2` for the
   new order, 1 = old); `mkadt.py` redfin clock values (cores 0-5 1.804, 6 2.208, 7 2.4 GHz) and cluster hints if XNU
   AMP support turns out usable (report what `cluster-type` E/P does on this kernel; do not enable blind).
P4 **(M)** 0963 DVFS governor: 20-50 ms timer per domain, utilisation → LUT index with hysteresis; silver floor ≈ 1.1 GHz,
   gold/prime ramp from their lowest row; `flamecpufreq=1` = old pinned behaviour, `=2` governor; perf-state writes only
   (no RPMh). Note gold and prime LUTs are both "2-core" domains in the DT (`qcom,freq-domain <3 1 2>/<3 2 2>`); treat
   core_count==max-1 rows as Linux does.
P5 **(M)** 0964 thermal caps: cap gold/prime index when any A76 sensor > 75 °C (release 65), harder at 85, isolate at 100;
   cap GPU level (`sweet_gpu.c:334`) at 85; camera/cpuss as skin proxies (skin ADC needs PMIC writes: not now). Log each
   step change once.
P6 **(M)** 0966 battery reporting: capacity 4000 mAh, poll 5-10 s, `IsCharging` = measured current > +50 mA, SoC seeded
   from SDAM 0xB147 (last Android SoC, if valid) then coulomb-counted from QG current with OCV correction; JEITA zone
   from 0x100D replaces the fixed 25 °C; keep the 1 % slew but per 5 s.
P7 **(S/M)** 0967 SPMI **write** path through the APID channel (chnls 0x0C600000 + 0x10000·APID, WDATA0 +0x10, CMD
   EXT_WRITEL, STATUS +0x08; owner check cnfg 0x0C40A000+0x700+4·APID == EE 0 first; read back every write), allow-list
   **only** SID 2 regs 0x1061, 0x1070, 0x1341, 0x1342, 0x1365, 0x1366, 0x1370; `sweetchg=0` disables all writes.
P8 **(M)** 0968 charger policy: read APSD_RESULT 0x1308 + TYPE_C_SNK_STATUS 0x1506 → ICL in HC mode the smblib way
   (write 0x1370, set 0x1366 bit0, clear 0x1342 bit0, set 0x1365 bit4): SDP 500, CDP/DCP/Rp1.5 1500, Rp3.0 2000 mA;
   FCC 0x1061 ≤ 2000 mA, FV 0x1070 ≤ 4.45 V; derate FCC by JEITA soft bits and die temp 0x1607 > 42 °C; **do not touch
   the SMB watchdog until 0x1651 is read and understood (P1)**; `poke w chg` prints the whole state.
P9 **(M, last, phone)** 0965 PSCI CPU_SUSPEND for CPUs 1-7: probe PSCI_FEATURES(0xC4000001) first; per-CPU power
   collapse param 0x40000003 (min residency 1774/2207 µs), later rail-pc 0x40000004 and last-CPU L3 0x41000044; **never**
   the notify-rpm states (0x41002244, 0x4100C244); resume through `resume_idle_cpu`, restore ICC regs + virtual timer;
   CPU0 stays WFI (its timer). `sweetidle=0/1`. Separate image, expect resets.
P10 **(M)** 0969 pollers: USB `ud_thread` 1 ms → event-driven or 10 ms when idle; (camera loop belongs to the camera chat).
P11 **(L, later)** iOS-visible thermal (thermalmonitord's FB sel 78; HID temperature services) — research note only now.
Exit tests (Fable): r21a = P1-P3 (temps + readbacks, nothing else changes); r21b = + governor; r21c = + thermal caps,
20 min Camera.app soak with `SWEET THERMAL`/`SWEET BATTERY` lines; r21d = charger writes with a wall charger, current
goes positive; r21e = PSCI idle.

### WS-S — Sensors (branch `ws-s-sensors`, Opus; CI now, phone after WS-D)
S1 **(M)** `phone/sensors/sensd`: QRTR over `/dev/redwood-qrtr` (3.1), reuse `phone/wifi/qmi.c` TLVs; SNS service 400:
   `SNS_CLIENT_REQ` 0x20 (TLV 1 = u16 len + protobuf; resp TLV 0x10 client_id), `SNS_CLIENT_REPORT_IND` 0x21 (TLV 1
   client_id, TLV 2 `sns_client_event_msg`); hand-written protobuf coder (varint/fixed32/fixed64/float/bytes, ~300 lines);
   SUID lookup sensor abababab…: msg 512 `sns_suid_req{data_type, default_only}` → event 768; attributes msg 1 → 128;
   stream `sns_std_sensor_config{sample_rate}` msg 513 (accel/gyro/mag/pressure), on-change msg 514 (prox/als); data
   msg 1025 `sns_std_sensor_event{repeated float, status}`; disable msg 10. **Verify ids/field numbers against libssc's
   .proto files first** (freedesktop iio-sensor-proxy MR 381 / pmaports MR 4050 carry them). `sensd --list`, `--stream
   accel 50`, `--all`; then writes `motion_sample`s to `/dev/redwood-motion`. Host-testable with a fake qrtr fd.
S2 **(M)** 0971/0972 kernel: `SweetHIDAccel/Gyro/ALS/Prox` (+Compass/Pressure) IOHIDEventService stand-ins next to
   `SweetHIDTouch` in the 0058 files (page 0xff00 usages accel 3, als 4, prox 8, gyro 9, compass 0xa — **verify** against
   IOHIDFamily's AppleHIDUsageTables), `/dev/redwood-motion` per 3.3 → `sweet_hid_sensor()`, **log every `setProperties`,
   open and client** (that is how we learn what backboardd/locationd/CoreBrightness want: ReportInterval, proximity mode…),
   `sweetmotion=0` disables.
S3 **(S)** `tools/adt.py` dump of the D22AP sensor nodes (`/arm-io/aop/iop-aop-nub` children: accel/gyro/als/prox) and
   whether `mkadt.py` must carry any `/product` capability flags; MobileGestalt keys to check on the phone.
S4 **(S)** launchd plist for sensd; NOTES.
Phone (Fable): node 5 service list shows 400 → `sensd --list` → accel at 50 Hz printed → autorotation (try
orientation events type 10 if raw accel does not rotate) → ALS in Settings auto-brightness → proximity (needs a call path
or a test app) → gyro in a test app. CoreMotion `deviceMotion` is the known risk; raw accel/gyro first.

### WS-B — Bluetooth (branch `ws-b-bluetooth`, Opus for btd, lighter model OK for 0980)
B1 **(M)** `phone/bt/btd` stage 1a, userland only over `/dev/pmem` as wland: RPMh votes (**add** smpa4 1.8 V; ldoc2 1.304,
   ldoc10 3.0-3.3, ldoa14 1.8 are wland's — vote again, never un-vote), TLMM 38-41 → `qup05`, GCC vote 0x52008 bit 15 +
   wrap0 AHB bits (as 0901), SE5 RCG cmd 0x17600 / CBCR 0x175fc (3.2 Mbaud = 51.2 MHz: 102.4 MHz row GPLL0_EVEN M/N
   128/375, divider 2), **check `GENI_FW_REVISION_RO` (SE+0x68) protocol byte == 2 (UART) first; stop if XBL did not load
   UART firmware** (then SE firmware load is a separate M task), polled GENI FIFO at 115200 with HW flow control; power
   pulse 0xFC + 100 ms, EDL version 0xFC00/0x19 (SoC id, ROM 0x32), baud change `01 48 FC 01 <idx>` (flow off around it),
   TLV download 0xFC00/0x1E in ≤243-B segments (rampatch then NVM, `crbtfw32.tlv` + `crnv32.bin`; pick `u` NVM by SoC
   id as btqca.c does), HCI Reset, BD_ADDR 0xFC0B from `mac-address-bluetooth0`, Read Local Version (manufacturer 29),
   LE scan 5 s. Exit: advertisements in the log.
B2 **(S)** 0980 bluetoothd/BlueTool probe: log every kernel-control `CTLIOCGINFO` name, every `open()` ENOENT under
   `/dev/bt*`, `/dev/*bluetooth*`, `/dev/uart*`, and IOKit matching dictionaries from those PIDs; `sweetbtlog=1`. Plus the
   spike script for the WSL root (strings/entitlements/LaunchDaemon plist/kext list/ADT `uart*`+`bluetooth` nodes) in
   `tools-claude/bt-spike.sh` — run by the user in WSL.
B3 **(M)** 0981 `sweet_geniuart.c`: `/dev/btuart` with the SPI 606 interrupt (0911) at 3.2 Mbaud, so btd stops polling.
B4 (decide after B2) 0982 stand-in transport (kctl `com.apple.uart.bluetooth`, `/dev/btwake` & co.) bridged to btd, with
   btd faking the Broadcom init/vendor commands; or the honest fallback (BLE for a test app/CLI only). Stage 3 is not
   started until B2's answers are in this doc.

## 5. Phase plan and phone schedule

Phase 1 (now, CI only, all five in parallel): D1-D5, A1-A5, P1-P8 + P10, S1-S4, B1-B3. Each worker ends with a report
(what landed, CI run ids, `BUILD.txt` commit, klog PA for kernels, the verify list) appended to section 6 by Fable.

Phase 2 (Fable, phone, in this order — each a RAM-only image, previous image stays bootable):
1. **r21a-e power** (P1-P8 first: independent, biggest comfort win, and the thermal/battery lines are needed to judge
   everything after). P9 PSCI last, own image.
2. **r22 DSP keep-alive** (D): hexagon files installed, fastrpcd, `adsp=1`; the gate test. Then B2's probe boot and B1's
   btd run can share this image.
3. **r23 sensors** (S) on r22: service 400 → sensd → HID.
4. **r24 audio** (A) on r22: tone → iOS sounds → mic.
5. Merge `redfin-qol` back onto `redfin-int` when the camera chat resumes; update `docs/redfin/port-plan.md`, `NOTES.md`,
   `redfin-automation-and-status.md`.

User actions needed (physical): get the phone from Android into fastboot when phase 2 starts; a wall charger (DCP or
Type-C 1.5 A+) for r21d; taps/rotations for sensor and audio tests; running `tools-claude/bt-spike.sh` in WSL.

## 6. Results log
(filled in as workstreams report)
