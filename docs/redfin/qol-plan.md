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

#### WS-A run book (patches 0952-0955, branch `ws-a-audio`)
Resolved: QUIN_TDM_RX_0 runs **4 slots x 32 bits** (kona.c `QUIN_TDM_MAX_SLOTS = 4` whenever the codec is a CS35L41;
the DT has no `qcom,tdm-max-slots`, default 8, and its 12.288 MHz is overridden by `set_sysclk(48000 x 32 x 4)` =
6.144 MHz); 2 active channels S32_LE at offsets 0/4, port mask 0x3; amps on ASPRX1 slot 0 (L, 0x40) / 1 (R, 0x41).
PRI_TDM_TX_0 (mics) runs 8 x 32 at 12.288 MHz, mic 1 at slot offset 0 (2nd/3rd: 8/12). Android enables an AFE group
only for >1 port or PRI_TDM_TX, so the speaker sends no group message.

Boot-args (all default off/old behaviour; all need `adsp=1`): `sound=1..4`, `sndsecs=S`, `sndlpi=0`, `sndbelow=E`
(1/8 dB under Android's level, default 160; sound=3 never louder), `sndgain=E` (sound=4 guard gain, default 96),
`sndgpio=1` (allow the PMIC GPIO writes: PM8150L GPIO10/11 amp resets, PM7250B GPIO6 mic LDO), `mic=1`, `micgain=N`.
Poke (`a`): `a status`, `a tone [MS]`, `a gain DB`, `a off`, `a on`, `a mic SECS`.

Phone order (one image per step): (1) `adsp=1 sound=1` -> `SWEET SOUND: LPASS core vote ... granted`, `LPI gpio6-9 now:`
(val 0x3c8 dir 0x2 = LPI writes work after the vote), `port 0x9040, started: done`; (2) `sound=2` -> `SMMU: ... IDENTITY`,
`ADM: COPP n open`, `PATH UP`, `tone over: ... the DSP took ~48000 frames/s`; (3) `sound=3` (+`sndgpio=1` if
`SWEET AMP: ... NO ANSWER`) -> `SWEET AMP: ... DEVID 0x35a40`, `AMPLIFIERS READY`, `amplifiers ON at 20.000 dB`,
audible 1 s tone, `amplifiers OFF (2 s of silence)`; `poke a tone 1000`; (4) `sound=4` -> Settings sounds;
(5) `mic=1` (+`sndgpio=1` for the mic LDO) -> `poke a mic 3`, then `files read /dev/pmem PA LEN` as printed
(raw S16LE mono 48 kHz; `sox -t raw -r 48000 -e signed -b 16 -c 1 mic.raw mic.wav`), then Voice Memos.

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

#### WS-S implementation notes (2026-10-26, branch `ws-s-sensors`)

**Pieces.** Kernel 0971 (`SweetHID.cpp`: `SweetHIDAccel/Gyro/ALS/Prox/Compass/Pressure/Orientation`, `SweetMotion.h`,
`AppleHIDUsageTables.h` filled in) and 0972 (`bsd/dev/sweet_motion.c`: `/dev/redwood-motion`, `poke m`). Userland
`phone/sensors/` (sensd, built and host-tested by userland.yml; `sh phone/sensors/test.sh` on any Linux/macOS host),
launchd job `phone/sensors/org.iosonpixel.sensd.plist`.

**Usage pairs** (verified): Apple vendor page 0xff00 usages accel 3, ALS 4, prox 8, gyro 9, compass 0xa are in
IOHIDFamily-1035.70.7's `AppleHIDUsageTables.h` (github.com/apple-oss-distributions/IOHIDFamily; from 1090 on the file
ships empty). Not verifiable from sources: the pressure service's pair (used: HID sensor page 0x20 / 0x31) and the
`kHIDUsage_AppleVendorMotion_DeviceOrientationType*` values an orientation event carries (used: `orientbase` +
UIDeviceOrientation, knob). Each service publishes Transport SPU, VendorID 0x5ac, BuiltIn, PrimaryUsagePage/Usage,
DeviceUsagePairs, ReportInterval (accel/gyro 10000, compass 20000, ALS/prox 100000, pressure 200000 µs),
SampleInterval, BatchInterval 0, HIDServiceSupport, Product = accel/gyro/als/prox/compass/pressure/orientation.

**SEE protocol** (sns.h has the whole map). Verified against Qualcomm's public docs: the SUID-lookup sensor
0xabababababababab (= 12370169555311111083), on-change config 514, disable 10, SUID req/event 512/768, the
sns_client_request_msg field order (suid, msg_id, susp_config, request) and sns_client_event_msg layout. **Not
verified** (libssc's .proto files are on codeberg/gitlab, which this container cannot reach): the protobuf field
numbers themselves, attribute ids, the QMI TLV numbers and the proximity event's msg id. sensd decodes defensively
(proximity told apart from 1025 by wire type; packed or unpacked floats), and `sensd --dump` prints every QMI
message in hex, so a wrong field number shows up on the first `--list`.

**Units and frames.** sensd writes Android/SEE units (motion.h); the kernel converts with integer arithmetic only:
accel g = accsign × m/s² / 9.80665 (accsign -1: CoreMotion face-up reads z = -1 g), gyro rad/s (`gyrodeg 1`: deg/s),
compass µT, pressure kPa, ALS lux (Level, RawChannel0, Illuminance; CCT when given), prox mask
LargeBodyContact|Receiver (0x41, knob) when near, level = raw. `poke m knob NAME V` changes these at run time.

**sensd.**

    sensd --list                  # kern.sweet_adsp_services, then per sensor: SUID, name/vendor/rates/range
    sensd --stream accel 50       # every sample; also als, prox (on change), gyro, compass, pressure
    sensd --all                   # one summary line per sensor per second
    sensd --daemon                # the boot job: follows ReportInterval (0 = off), restarts on DSP loss
    options: --dump --secs N --no-motion --no-orient --no-follow --node N --port P

It also derives type-10 orientation samples from accel (300 ms settle). Install: `files put` the binary to
`/var/local/bin/sensd` (755), then add the job to the root image's launchd.plist (as wland's):

    sudo python3 -I - "$M/System/Library/xpc/launchd.plist" <<'PY'
    import plistlib, sys
    p = plistlib.load(open(sys.argv[1], 'rb'))
    p['LaunchDaemons']['/System/Library/LaunchDaemons/org.iosonpixel.sensd.plist'] = {
        'Label': 'org.iosonpixel.sensd', 'ProgramArguments': ['/var/local/bin/sensd', '--daemon'],
        'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 10, 'UserName': 'root',
        'StandardOutPath': '/var/local/sensd.log', 'StandardErrorPath': '/var/local/sensd.log',
        'EnvironmentVariables': {'PATH': '/var/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'}}
    plistlib.dump(p, open(sys.argv[1], 'wb'), fmt=plistlib.FMT_BINARY)
    PY

Off switch without a rebuild: `/var/local/sensd.off`.

**S3: the D22AP tree** (`research/ipsw-x/d22ap.adt` on the PC; `tools/adt.py` has only `dump`, so this uses its
parser). Print every subtree whose name or compatible matches:

    python3 - research/ipsw-x/d22ap.adt <<'PY'
    import re, sys; sys.path.insert(0, 'tools'); import adt
    root, _ = adt.parse(adt.load(sys.argv[1]))
    pat = re.compile(sys.argv[2] if len(sys.argv) > 2 else r'aop|spu|accel|gyro|als|prox|compass|press|motion|orient|baro|mag', re.I)
    def walk(n, path):
        p = path + '/' + n.name
        if pat.search(n.name) or pat.search((n.prop('compatible') or b'').decode('latin1')):
            print('==', p); adt.dump(n, 1)
        else:
            for c in n.children: walk(c, p)
    walk(root, '')
    PY
    # then the same with the pattern '^product$' for /product, and: python3 tools/adt.py dump research/ipsw-x/d22ap.adt | less

Look for: (1) `/arm-io/aop` (and `iop-aop-nub`, `spu`, `aop-*`) children named accel/gyro/als/prox/compass/pressure
and their `compatible` strings; (2) placement/orientation/rotation matrices or calibration blobs (`*-placement`,
`*-matrix`, `als-*`, `prox-*`): those are what the real drivers read, and would only matter if a user-space
daemon reads them from the registry (then mkadt.py must carry them under `/arm-io/aop/...`); (3) `/product` keys
that look like capabilities (mkadt.py copies /product whole today, so anything there is already on the phone). If the
D22AP tree has a sensor node and backboardd/locationd log about a missing "accel"/"aop" service, the next step is
to name our services after those nodes (`IOName`), not to add DT nodes.

**MobileGestalt** (`mg_test KEY...` on the phone; nil = MobileGestalt does not know the key):
`accelerometer gyroscope magnetometer ambient-light-sensor proximity-sensor` (UIRequiredDeviceCapabilities names; the
first three are certain, the last two candidates), plus `DeviceSupportsAutoBrightness`, `barometer`,
`HasBaseband` for comparison. All should already be true from the D22 identity; a false/nil one says where iOS
decides "no such sensor" before ever opening a service.

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

**WS-B tools (phase 1, CI only).** `phone/bt/btd` (userland.yml; host test `tlv_test.c` runs first: TLV segmenter,
NVM edits, the whole bring-up against a fake controller; its log ships as `tlv_test.log`). Install to
`/var/local/bin/btd`; firmware `crbtfw32.tlv`, `crnv32.bin`, `crnv32u.bin` from Android's `/vendor/firmware` to
`/private/var/local/fw/` (never in git). `btd --probe` | `--up` | `--scan [S]` | `--raw [PORT]`; options `--baud`
(default 3000000: 96 MHz source at CX LOW; 3.2 M needs 102.4 MHz = NOMINAL), `--os 16|32`, `--pmem`, `--fw/--nvm/--fwdir`,
`--ibs` (keep the NVM's in-band/deep sleep; default off so the host needs no IBS), `--bdaddr`, `--noinit`, `-v/-q`.
Backend `/dev/btuart` (0981, `btuart=1`) if present, else SE5 polled over `/dev/pmem`. Result lines `BTD PROBE`,
`BTD UP`, `BTD ADV`, `BTD SCAN`, `BTD RAW`, failures `BTD FAIL <step>: <meaning>`; exit 0 ok, 1 failure, 3 up but
no advertisement. `--raw`: `ssh -L 2225:127.0.0.1:2225 phone`, then on Linux
`socat PTY,link=/tmp/btpty,raw,echo=0 TCP:127.0.0.1:2225 & btattach -P h4 -B /tmp/btpty` (or any H4 client).
0980 `sweetbtlog=1` (grep `SWEET BTLOG` and `IOK bluetoothd|IOK BlueTool|IOK wirelessproxd`), 0981 `btuart=1`
(`SWEET BTUART`, poke `b 0|1|2`). `tools-claude/bt-spike.sh ROOT [--adt DT] [--kc KC]` in WSL: launchd jobs,
binaries + linked libraries + entitlements, strings by topic in the daemons and the shared cache, firmware dirs,
ADT uart/bluetooth nodes, kernelcache kexts; report in `bt-spike-report.txt`.

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

### 2026-10-26 01:20 — Phase 1 done, Phase 2a on the phone (power)

Phase 1: all five branches green in CI. ws-p-power @ 7f6f188 (0960-0969, klog PA 0x101d1a8d8); ws-a-audio @ 9cf0607
(0952-0955); ws-s-sensors @ 87c444e (0971-0972 + phone/sensors/sensd); ws-b-bluetooth @ 6ceb76d (0980-0981 +
phone/bt/btd); ws-d-fastrpc @ 79979fd (0950, 0951, 0956 kernel done; **phone/fastrpc/fastrpcd not written**: the
worker was stopped twice by the safety classifier while writing the userland daemon; design and the exact remaining
work are in the project doc "fastrpcd Technical Brief"). All merged into `redfin-qol` @ 121bbfb; 0960/0961/0972/0981
were regenerated against the merged tree (their bsd/conf/files and sweet_poke.c context had moved; CI would have
silently skipped them). Merged kernel + userland CI runs 40248921561 / 40248923960.

Phone (images r21a-e = ws-p-power kernel + r19a ADT; r21a = r19a's command line, r21b+ = flamereboot=0):
- **r21a** (no new args): TSENS works (tsens0/1 trdy ok): 40 C at boot, 63-74 C during the boot storm with all 8
  cores at max clock and ~97 % busy. Battery: SDAM valid, SOC seeded 52 %, counted SOC; boot regs FCC 2000 mA,
  FV 4450 mV, ICL cfg 1500 mA, JEITA_EN 0xd0, WD_CFG 0 (no watchdog), SBB 0x0c; 1366=02 (USB51 mode) so the
  effective ICL on the PC port was 500 mA (1107=0a) although cfg said 1500. LMh raw 0 (not limiting).
- **r21b** (flamecpufreq=2): governor works: at idle gold 652 / prime 806 MHz, silver 1363-1804; temperatures
  fall to ~54 C within a minute of the boot storm ending (were ~70 C pinned). "gov on a/b/c changes" counts rise.
- **r21d** (+ sweetbig=2 sweettcap=3 sweetchg=1): SPMI writes work: `write 2:1366 = 03 (was 02) -> reads 03 ok`,
  `1365 = b5 (was a5)`, no owner/mismatch errors. First APSD said CDP -> HC mode 1500 mA, but AICL then
  collapsed to 50 mA (soft-ilimit: the PC port cannot source it); `poke w chg apsd` re-ran APSD -> SDP -> hardware
  500 mA, battery -67 mA at idle (was -221 on r21b, -640 with the camera on r18). On a power bank the user's meter
  showed **9.5 W** drawn (= the 2 A tier) — klog to be read when the phone is back on the PC.
- r21c's args are inside r21d.

### 2026-10-26 02:10 — r21e, r22b-g (merged kernel), bisect of the sensor crash

- **r21e (sweetidle=1, PSCI power collapse):** works first time. `PSCI_FEATURES(CPU_SUSPEND) = 3`, memory-mapped
  broadcast timer frame 0 (CNTACR0 -> 3f) on CPU0, CPUs 1-7 in state 0x40000003: ~160k pc/resume in 2 min, err 0,
  no panic. Idle battery -73 mA on the PC port (same as without; the gain is under load/heat, not at idle).
- **Merged kernel** (redfin-qol 121bbfb, then e03ca00 with 0971 "Sweet" transport): klog PA **0x101d428d8**.
- **r22b (adsp=1 sweetbtlog=1):** WS-D kernel half proven: `fastrpcglink-apps-dsp` opens both ways, pd-mapper answers
  the DSP's lookups (avs/audio 1 domain, tms/servreg 3 domains); the sensors PD still dies at 73 s with 0 FastRPC
  messages (no daemon yet). **Bluetooth:** bluetoothd registers IOKit notifications `IONameMatch "marconi-bt"` and
  `IONameMatch "bluetooth"` (-> none); no kctl/dev-node attempts in 3 min. WS-B's 0982 (`sweetbtnub=1/2/3`) publishes
  stand-in nubs with full property-read logging for the next probe boot (ws-b-bluetooth @ ed160ed, PA 0x101d16710).
- **Sensors:** backboardd matches and opens all seven HID stand-ins and configures them (DeviceOpenedByEventSystem,
  MotionEventRestricted=false, LogLevel, PreserveTimestamp, ReportInterval 0 / BatchInterval; the ALS gets
  `ALSLPannelValues`). **But backboardd crash-loops** (every ~10 s) with `*** Terminating app due to uncaught exception
  'NSInvalidArgumentException', reason: '-[NSNull applyUIMode:]'` after `AppleSPUKext/liblog_aop.cpp:135` asserts.
  Bisect: sweetmotion=0x03 (accel+gyro) stable (r22d); 0x7f crash (r22b/e, Transport SPU and Sweet alike); 0x7b (no
  ALS) crash (r22f); 0x6b (no ALS, no compass) crash (r22g) => the trigger is prox (0x08), pressure (0x20) or
  orientation (0x40). `poke m rot 3` on r22d (fake accel -1 g x) did **not** rotate Safari: backboardd had set the accel
  ReportInterval to 0 (not consuming raw accel); rotation presumably needs the orientation service (type 10), which is
  in the suspect group. **Phone left on r22d** (merged kernel, power on, accel+gyro only).
- Charging: the 9.5 W seen on the power bank was with the phone reset (the ring ended at 287 s): the PMIC's own
  defaults with a real charger, not our policy. Policy test with a wall charger still open.
