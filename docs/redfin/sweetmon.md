# sweetmon: live CPU/GPU/thermal monitoring and one-button traces (branch ws-z-mon, 2026-10-29)

Goal: see what makes the phone slow and hot, live, on the PC, with as little extra load on the phone as possible;
start/stop traces from a dashboard button or from Claude (phone agent); no more slow klog/trace pulls.

## Pieces

| Piece | Where | What |
|---|---|---|
| `sweetmon` | phone, /var/local/bin/sweetmon (source phone/tools/sweetmon.c) | one small daemon: samples, tails the kernel log ring, records traces in RAM, serves one TCP client |
| collector | PC/WSL, tools-claude/sweetmon/collector.py (python3 stdlib only) | connects to the phone (USB or Wi-Fi), keeps everything on disk, serves the dashboard + JSON API |
| dashboard | tools-claude/sweetmon/dashboard.html, served at http://localhost:8765/ | live charts, process table, klog tail, trace buttons |
| agent actions | tools-claude/phone-agent.sh `mon ...` | Claude's hook: start/stop traces, snapshots, link choice, install |

Data that already exists and is reused (no kernel change needed for v1):
- kernel 5 s tick lines in the log ring: `SWEET THERMAL: silver .. gold .. prime .. cpuss .. gpu .. ddr .. cam .. npu .. aoss .. C`,
  `SWEET THERMAL: level A -> B ...` (caps), `SWEET CPUFREQ: busy c0 c1 c2 c3 c4 c5 | c6 | c7 %; silver IDX=MHZ MHz (cyc N, lmh N) gold ... prime ...`,
  `SWEET BATTERY: ...`, the GPU 5 s line `5s: N submits (M missed), GPU busy X ms (Y%), longest .. us, mean .. us; <who>`
  (per-process GPU time), `SWEET PROF: ...` (kernel sampling profiler, started by poke `p prof start NAME|PID HZ SECS`).
- sysctls `kern.sweet_temp_{silver,gold,prime,cpuss,gpu,ddr,camera,npu,aoss,max}` (deci-degC, updated every 5 s).
- kernel log ring: u64 total at KLOG_PA, then a 4 MiB ring (byte i at KLOG_PA+8+(i % 4 MiB)); readable by root via
  /dev/pmem (pread at offset = PA). r63a kernel: KLOG_PA = 0x101d0ef08. Every build folder has KLOG_PA.txt.
- kdebug frame events (0994, class DBG_DRIVERS subclass 0xF5) and the .swtr trace format of sweettrace (ws-u-lab version
  with -f/-z) read by tools-claude/sweet-trace.py.
- CPU layout: cpu0-5 silver (A55), cpu6 gold (A76), cpu7 prime (A76).

## Load on the phone (design rules)
- One process, no fork/exec in steady state, no files written on the phone (no flash I/O), nothing on stdout.
- Default sample period 1000 ms (range 200..10000), process table every 2nd sample (configurable). Klog tail polled
  every 250 ms, sent only when new bytes exist. Everything idles when no client is connected (only accept()).
- Traces are recorded into RAM (kernel kdebug buffer + process memory). In the default "buffer" mode nothing is sent
  while a trace runs; data is LZ4-compressed and sent after stop. "stream" mode sends chunks during the trace.
- The daemon reports its own CPU time and memory in every sample, so its cost is always visible.
- nice 10. Timers via kevent/select, not busy loops.

## Wire protocol (TCP 5150 on all interfaces; one client; a new authenticated client replaces the old one)

Frame = u32 LE `len` (bytes after this field) + u8 `type` + payload (`len - 1` bytes). Max frame 4 MiB.

Authentication: the phone reads a token from /var/local/sweetmon.key (one line, hex). Until the client sends
`C` "auth TOKEN", the phone answers only `H` and an `R` error. If the key file is missing the daemon refuses to start
unless run with `-k TOKEN` or `-K` (no auth; for tests only).

Client -> phone: type `C`, payload = one ASCII command line. Phone -> client: types below. Every command gets exactly
one `R` reply: JSON `{"cmd":"<first word>","ok":true|false,"msg":"...", ...}`.

| Type | Payload | When |
|---|---|---|
| `H` | JSON hello: `{"v":1,"pid":..,"uptime_s":..,"ncpu":8,"tb_numer":..,"tb_denom":..,"boottime":<unix s>,"ifaces":{"en0":"192.168.1.x",...},"klog_pa":"0x..."|null,"version":"<git sha or date>"}` | on connect |
| `S` | JSON sample (below) | every period |
| `K` | raw klog bytes (UTF-8-ish text, may split lines) prefixed by u64 LE ring position of the first byte | when new log bytes |
| `R` | JSON reply | per command |
| `T` | u32 LE trace id + u32 LE seq + chunk bytes (LZ4 frame data of the trace file, see Traces) | trace data |
| `E` | JSON trace end `{"id":..,"kind":"kdebug"|"pmem","bytes":<uncompressed>,"zbytes":..,"events":..,"threads":..,"wrapped":bool,"lost":..,"secs":..,"cpu_ms":<daemon cpu used for it>}` | after the last `T` |
| `F` | JSON frame stats (light frame mode, below) | every period while on |
| `P` | filler bytes (speed test) | after `speed` |

### Commands
- `auth TOKEN`
- `rate MS [TOPEVERY]` sample period, process table every TOPEVERY samples (default 1000 2)
- `top N` processes in the table (default 15; 0 = off)
- `klog PA` start tailing the ring at physical address PA (the daemon checks: total <= 2^40, the last 4 KiB of the ring
  contain printable text; reply ok/false with the reason). `klog off`. `klog from POS` resend from ring position POS
  (if still in the ring) so the PC can fill a gap after a reconnect. On start the daemon sends the whole ring content
  (up to 4 MiB) once, then increments.
- `trace start kdebug [secs=N] [mode=buffer|stream] [filter=f|none|P1,P2] [classes=..] [syscalls=0|1] [intr=0|1]
   [kbuf=EVENTS] [max_mb=N] [quiet=0|1]` -> reply with `"id"`. Defaults: secs=60 (hard cap 600), buffer mode,
   filter=f (sweettrace -f rules), sched+IPC+intr+0xF5, max_mb=512. quiet=1 pauses sampling/klog while recording.
   Ends at `trace stop`, at secs, or when max_mb is reached (`"lost"`/`"wrapped"` in `E` tell the truth).
- `trace stop` / `trace abort` (abort: nothing sent).
- `pmem PA LEN [id]` read physical memory once and send it as a trace (kind pmem; LEN <= 64 MiB) — used for the kernel
  profiler's buffer (`SWEET PROF: ... buffer N KiB at pa 0x...`).
- `frames on|off` light frame mode: kdebug enabled with a typefilter of only the 0xF5 present/shown/vsync/GPU-done codes,
  read once per period; `F` = `{"t":..,"frames":N,"fps":..,"vsync":N,"gpu_ms_p50":..,"gpu_ms_p90":..,"present_to_shown_ms_p50":..}`.
  Off by default (kdebug enabled has a small cost everywhere); `trace start` takes over kdebug and frame mode resumes after.
- `speed MB` send MB MiB of incompressible `P` frames, then `R` with the phone-side seconds and daemon cpu_ms.
- `ping X` -> `R` msg X (round-trip time).
- `info` -> `R` with build, config, kdebug owner state, memory use.
- `quit` -> daemon exits (the collector restarts it over ssh when wanted).

### Sample `S`
```
{"t":<mach abs ns>,"up":<s>,"dt_ms":<since last>,
 "cpu":[[user,sys,idle,nice],...8],            # tick deltas per core (host_processor_info)
 "temp":{"silver":412,...,"max":..},             # deci-degC from kern.sweet_temp_*
 "vm":{"free":p,"active":p,"inactive":p,"wired":p,"compressed":p,"spec":p,"pageins":d,"swapins":d,"faults":d,"page_kb":16},
 "load":[1m,5m,15m],
 "procs":[[pid,"name",cpu_ms_delta,wakeups_delta,footprint_kb,threads,diskio_kb_delta],...],   # only every TOPEVERY samples, sorted by cpu
 "nproc":N,
 "self":{"cpu_ms":delta,"rss_kb":..,"klog_bps":..,"tx_bps":..},
 "klog_bps":<kernel log bytes/s written by the kernel (ring total delta)>}
```
wakeups = rusage_info_v4 ri_interrupt_wkups + ri_pkg_idle_wkups (deltas). The first sample after connect has deltas
from daemon start.

### Traces
The trace bytes are exactly the .swtr file sweettrace writes (header, kd_buf events, thread map; the -f reduction
when filter=f), compressed as one LZ4 frame (lz4frame format) split into `T` chunks of <= 1 MiB. The collector writes
`logs/traces/<NAME>-<MMDD-HHMMSS>/trace.swtr` (decompressed with python's `lz4` module if present, else the bundled
pure-python LZ4 frame decoder tools/lz4py.py), then runs `sweet-trace.py --summary-json` in the background.

## Collector (PC)
- Links: `usb` = 192.168.7.2:5150, `wifi` = the phone's en0 address learned from `H` (saved in
  logs/mon/phone.json), `auto` = USB if it answers, else Wi-Fi. Reconnects every 2 s. When the phone answers ssh but
  not 5150 it starts the daemon: `ssh root@HOST /var/local/bin/sweetmon -D` (agent key ~/.ssh/redfin-claude).
- On connect: auth, `rate`, `klog PA` (from logs/mon/config.json `klog_pa`, default the KLOG_PA of the newest status
  doc's kernel; `mon klog-pa PA` changes it), `klog from POS` after a reconnect within the same boot.
- Writes: logs/mon/now.json (latest merged snapshot, every sample — Claude reads this file directly),
  logs/mon/metrics-YYYYMMDD.jsonl (every sample), logs/mon/klog-<boot>.txt (the full kernel log, appended; replaces
  `klog PA` pulls), logs/traces/... . Parses the klog lines above into the snapshot (cpufreq, gpu, battery, thermal level).
- HTTP 127.0.0.1:8765: `/` dashboard, `/api/stream` (SSE: hello, sample, klog lines, trace events), `/api/now`,
  `/api/history?secs=N`, `/api/klog?n=N&grep=RE`, `POST /api/trace/start` (JSON: kind kdebug|prof, name, secs, opts),
  `POST /api/trace/stop`, `GET /api/traces`, `POST /api/cmd` (raw command, for debugging), `POST /api/link` (usb|wifi|auto),
  `POST /api/speed` (MB), `POST /api/frames` (on|off).
- Kernel profiler traces (kind prof): poke `p prof start NAME HZ SECS` through tools/flame-cmd.py (USB only), wait for
  the `SWEET PROF: ... buffer N KiB at pa 0x...` line in the klog stream, then `pmem PA LEN`, then sweet-prof.py.

## Agent actions (Claude)
`mon-start` / `mon-stop` / `mon-status` (collector process), `mon trace NAME [kdebug|prof] [SECS] [k=v...]`,
`mon stop`, `mon snap` (text summary of now.json), `mon link usb|wifi|auto`, `mon speed [MB]`, `mon frames on|off`,
`mon install` (files put sweetmon + key, start it), `mon klog-pa PA`. Results also land as files in logs/mon and logs/traces.
