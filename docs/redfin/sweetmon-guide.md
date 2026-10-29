# sweetmon guide: live monitor and traces for the redfin port (2026-10-29)

For a new Claude chat or subagent. What sweetmon is, where everything is, how to use it from the phone agent and from
files, and what it found on day one. Design and wire protocol: `docs/redfin/sweetmon.md` (branch ws-z-mon). Code
README: `tools-claude/sweetmon/README.md`. This guide wins where they disagree about current behaviour.

## 1. What it is and where things are

sweetmon is a small daemon on the phone plus a collector on the PC. The daemon samples CPU, temperatures, VM,
processes and the kernel log ring, and records kdebug traces in RAM. The collector keeps everything on disk and serves
a dashboard. It replaces `klog PA` pulls, hand-run sweettrace and repeated `phone psx` polling.

| Piece | Where | Notes |
|---|---|---|
| daemon | phone `/var/local/bin/sweetmon` (src `phone/tools/sweetmon.c`, built from ws-z-mon 645854a, hello version `645854a7`) | TCP **5150**, all interfaces, nice 10, writes nothing to flash |
| daemon key | phone `/var/local/sweetmon.key` (600); PC copy `agent/sweetmon.key` | **never print it, never commit it** |
| collector | WSL `tools-claude/sweetmon/collector.py` (python3 stdlib) | started by the phone agent (at agent start and whenever USB comes up) |
| dashboard | `tools-claude/sweetmon/dashboard.html`, served at **http://localhost:8765/** | Windows browser, also works in the Claude desktop app's browser pane |
| Claude's hook | `tools-claude/phone-agent.sh` actions `mon-start`, `mon-stop`, `mon-status`, `mon ...` | calls `collector.py ctl ...` -> the collector's HTTP API |
| data | `logs/mon/`, `logs/traces/` in the project folder | readable directly over device_bash, no agent round trip |
| tests | `tools-claude/sweetmon/fakephone.py`, `e2e-test.sh` | fake daemon + end-to-end test, no phone needed |
| test client | `tools/sweetmon-client.py` | raw protocol client. Don't use it while the collector runs (single client slot, see 7) |

Daemon flags (`sweetmon.c` usage): `sweetmon [-D] [-p PORT] [-k TOKEN | -K] [-l LOGFILE] [-v]`, `sweetmon -Z IN OUT`
(LZ4 writer test). `-D` daemonizes. Without a key file it refuses to start unless `-k`/`-K` (no auth, tests only).

**Not started by launchd yet.** After every phone reboot the daemon must be started again. The collector does this
by itself: when the phone answers ssh but not 5150, it runs `ssh root@HOST /var/local/bin/sweetmon -D` (key
`~/.ssh/redfin-claude`, at most every 30 s per host).

Claude's own shells (container Bash and device_bash) **cannot reach localhost:8765 or the phone's 5150**. Use the
`mon` agent actions or read the files.

## 2. Starting and checking it

| Request line (agent/inbox/NAME.req) | What you get |
|---|---|
| `mon-status` | `collector running (pid N)`, link mode/via/host, connected or the reason, rtt, reconnects, klog status/file/pos/lost, current or last trace, last speed test, last 5 lines of collector.log |
| `mon-start` | starts the collector if it isn't running (also makes agent/sweetmon.key on first use) |
| `mon-stop` | stops the collector (frees the phone's single client slot) |
| `mon snap` | text summary of now.json: hot lines, temps, CPU, GPU, top processes, klog, sweetmon cost, STALE marker |

Agent mechanics (same as every other action): one line in `agent/inbox/NAME.req`, unique NAME each time; answer in
`agent/outbox/NAME.out`, first line `$ <request>`, last line `== exit N at HH:MM:SS`. **The agent runs requests one
at a time**: a `mon wait 150` or a big `mon speed` blocks every other request (including another agent's) until it
returns. Keep waits short (<= 120 s) and split them, as device_bash itself times out around 180 s.

### Dashboard won't open (localhost refused)
1. Collector not running: `mon-status`; read `logs/mon/collector.log`. `mon-start` restarts it. The phone agent
   itself must be running in WSL (ask the user to start it if the outbox stays empty).
2. WSL localhost forwarding off (`localhostForwarding=false` in `%UserProfile%\.wslconfig`, or mirrored networking
   misbehaving): the user starts the collector by hand with `--http-host 0.0.0.0` and opens
   `http://<WSL address>:8765/` (`hostname -I` in WSL). That exposes the port on the LAN: trusted network only.
   (`mon-stop` first, or the agent's copy holds port 8765.)
3. No browser at all: `logs/mon/now.json` and `mon snap` have the same data as text.

Useful collector flags (`collector.py --help`): `--root`, `--link auto|usb|wifi`, `--http-host`, `--http-port 8765`,
`--wifi-host`, `--no-autostart`, `--keep-lz4`, `--history-secs 3600`, `-v`, `--make-key [--force]`, `ctl ...`.

## 3. Claude's hooks (agent request lines)

All `mon` arguments must match `[A-Za-z0-9._=,:/ -]`. Each returns JSON from the collector (exit 1 if `ok:false`).

| Request line | Effect / notes |
|---|---|
| `mon snap` | one-screen summary of the latest sample |
| `mon trace NAME` | kdebug trace, 60 s default (phone cap 600 s); NAME becomes `logs/traces/NAME-MMDD-HHMMSS/` |
| `mon trace NAME kdebug SECS [k=v ...]` | kdebug options below |
| `mon trace NAME prof SECS [target=PROC] [hz=N] [kernel=builds/xnu/DIR/kernel...gz]` | kernel sampling profiler; target defaults to NAME, hz 1000, SECS default 10. USB only (poke) |
| `mon stop` / `mon stop abort` | stop the running trace (data is sent and analysed) / abort it (nothing sent) |
| `mon traces [N]` | current trace + last N (default 10): dir, kind, state, transfer s, MB/s, file sizes, error |
| `mon wait [SECS]` | wait (default 150 s) until no trace is running, print the newest trace's meta; exit 0 if `done` |
| `mon link usb\|wifi\|auto` | pick the link (saved in logs/mon/config.json). Default and normal value: auto |
| `mon speed [MB]` | speed test over the current link (default 16 MiB, max 256), saves MB/s per link in phone.json, teaches auto |
| `mon frames on\|off` | light frame mode (kdebug 0xF5 frame codes only, `F` stats every sample) |
| `mon klog-pa PA` / `mon klog-pa auto` | set / clear the kernel log ring address (see recipe 9.6) |
| `mon rate MS` | sample period 200..10000 ms (process table stays every 2nd sample). Default 1000 |
| `mon cmd LINE` | raw daemon command (debugging only, e.g. `mon cmd info`, `mon cmd ping x`) |
| `mon install` | `files put` newest `builds/userland/*/sweetmon` -> /var/local/bin/sweetmon (755), the key over ssh (600), start `sweetmon -D` |

kdebug options (`k=v`, passed to the daemon's `trace start kdebug`):

| Option | Default | Meaning |
|---|---|---|
| `filter=f\|none\|P1,P2` | `f` | `f` = sweettrace -f rules, focus backboardd,SpringBoard,Preferences; `none` = everything; or a process list |
| `classes=..` | sched+IPC+intr+0xF5 | kdebug classes |
| `syscalls=0\|1` | 0 | include syscalls |
| `intr=0\|1` | 1 | interrupts |
| `kbuf=EVENTS` | 1048576 | kernel buffer (min 65536; halves until the kernel accepts) |
| `max_mb=N` | 512 | stop at this many MB of events (`lost`/`wrapped` in meta tell the truth) |
| `quiet=1` | 0 | pause sampling and klog while recording |
| `app=NAME` | - | collector only: passed to sweet-trace.py `--app` for the analysis |
| `mode=stream` | - | **refused by the daemon** ("only mode=buffer in v1"); don't pass it |

A trace's lifecycle (`state`): recording -> transferring -> analyzing -> done (or failed/aborted). Analysis runs
`sweet-trace.py --summary-json` (kdebug) or `sweet-prof.py report --top 30 --folded` (prof) in the background.

## 4. Files Claude reads directly (no agent round trip)

All under `$HOME/mnt/iOS_Pixel5/` in device_bash. Read with head/grep/python; nothing here needs the phone.

| File | Content |
|---|---|
| `logs/mon/now.json` | latest merged snapshot, rewritten atomically every sample (1 s) |
| `logs/mon/klog-<boottime>.txt` | full kernel log of that boot (boottime = unix seconds from hello), gap-filled after reconnects |
| `logs/mon/metrics-YYYYMMDD.jsonl` | one compact line per sample (flushed every 10 samples) |
| `logs/mon/collector.log` | collector events: connects, daemon starts, traces, speed tests, warnings |
| `logs/mon/config.json` | `link, rate_ms, top_every, top, frames[, klog_pa]` |
| `logs/mon/phone.json` | remembered Wi-Fi address, last hello, per-link speed results |
| `logs/mon/state.json` | `boot, klog_pos, klog_file, klog_lost` (gap fill across collector restarts) |
| `logs/mon/collector.json` | collector pid, start time, HTTP address |
| `logs/traces/NAME-MMDD-HHMMSS/` | one finished trace (below) |

### now.json fields (real names, from the live file)
- `t` (unix s of the sample), `time`; when the link is down the collector rewrites the file with `stale: true` and
  `age_s`. Otherwise compare `t` with the clock.
- `link`: `mode, via, host, connected, authed, rtt_ms, since, reconnects, rx_bps, msg, wifi_host, usb_host,
  speed.{usb,wifi}.{mbps,mb,t,host,rtt_ms}, preferred`.
- `phone`: `uptime_s, daemon_pid, version, boottime, ifaces, ncpu, nproc, rate_ms`.
- `cpu`: `busy[8]` (% per core, cpu0-5 silver A55, cpu6 gold, cpu7 prime), `avg`, `clusters.{silver,gold,prime}.
  {busy,mhz,idx}`, `load[3]`, `kernel_busy[8]` (from SWEET CPUFREQ), `cpufreq_age_s`.
- `temp`: `silver gold prime cpuss gpu ddr camera npu aoss max` in °C; `temp_source` (`sysctl` or klog).
- `thermal`: `level, cap_mhz.{silver,gold,prime}, gpu_cap, hot_c, since_up_s`.
- `battery`: `mv, ma` (negative = discharging), `pct, ext, chg, temp_c, age_s`.
- `gpu`: `submits, missed, busy_ms, busy_pct, longest_us, mean_us, owners[{name,submits,ms}], age_s` (5 s line).
- `fb`: `swaps, shown, dropped, fps, p50_ms, p95_ms, hz, age_s` (SWEET FB 5 s line).
- `mem`: `free_mb active_mb inactive_mb wired_mb compressed_mb spec_mb used_mb pageins_s swapins_s faults_s`.
- `procs`: `by_cpu[{pid,name,cpu_pct,wakeups_s,mem_mb,threads,disk_kbs}]` (top 15), `by_wakeups` (top 10),
  `interval_s`. cpu_pct is % of one core.
- `klog`: `bps_kernel` (bytes/s the kernel writes), `bps_rx`, `top_tags[{tag,bps,lines_s}]`, `file`, `pos`,
  `lost_bytes`, `status` (which PA and where it came from), `pa`.
- `crashes[{ts,name,pid,sig,line}]` (last 10 CRASH lines), `self.{cpu_pct,cpu_ms_s,rss_mb,tx_bps,klog_bps}`
  (the daemon's own cost), `frames` (null unless frames mode), `frames_on`, `trace` (current or last trace's meta),
  `hot[]` (the collector's "what makes it hot/slow" lines, most important first).

Quick read: `python3 -c "import json;d=json.load(open('logs/mon/now.json'));print(d['time'],d['hot'],d['temp']['max'],d['self'])"`

### klog-<boot>.txt instead of `klog PA`
The collector tails the ring from the daemon (first a full ring dump, then increments), so the whole log of the
current boot is already on the PC. `grep` it instead of sending `klog PA` (which costs a pull and a round trip). A
`[sweetmon: N bytes of kernel log lost here]` marker shows where the 4 MiB ring overran while nobody was connected.
Pick the newest file by mtime, or `now.json` `klog.file`. (`klog-test1.txt` is from the e2e test; ignore it.)

### metrics-YYYYMMDD.jsonl row
`t, up, busy[8], mhz[silver,gold,prime], temp{...}, lvl, gpu, bat_ma, bat_pct, mem_free, mem_used, mem_comp,
klog_bps, self_cpu, self_ms, fps, fb_fps, rtt` and, on samples with a process table, `top[[name,cpu_pct,wakeups_s]
x5]`. One file per local day; up to 10 most recent rows may still be in the write buffer.

### Trace folder `logs/traces/NAME-MMDD-HHMMSS/`
| File | kdebug | prof |
|---|---|---|
| `trace.swtr` / `prof.bin` | the .swtr sweettrace would write (decompressed) | the kernel profiler buffer |
| `meta.json` | name, kind, state, secs, opts, msg (the daemon command), error, recording_s, zbytes, chunks, transfer_s, transfer_mbps, `end` (bytes, zbytes, events, threads, wrapped, lost, secs, cpu_ms) | same |
| `summary.json` | `sweet-trace.py --summary-json`: label, span_ms, frames, stage_gaps_ms, largest_gap_counts, display_thread_oncpu_ms, app_main_oncpu_ms, ipc_top, warning | - |
| `report.txt` | analyzer text output | sweet-prof report, top 30 |
| `prof.folded` | - | folded stacks (flame graph input) |

## 5. The user's dashboard (http://localhost:8765/)

- Header tiles: link + ping, uptime, battery % and mA, max temp, thermal level, CPU avg, GPU, **sweetmon cost**
  (ms/s, % of a core, RSS). Controls: window 1/5/15 min, link auto/USB/Wi-Fi (each shows its last MB/s; star =
  auto's choice), speed test (MiB box), theme.
- Hot line under the header: same as now.json `hot`.
- Panels: CPU busy per core; cluster clocks; temperatures; GPU busy + owners; memory; frames (checkbox = light frame
  mode); processes (sortable; **click a row to make it the profiler target**: kind switches to kernel profiler, name
  and target are filled in); kernel log rate + top tags (click a tag to filter the log); kernel log tail (regex
  filter, pause, clear); trace form and trace list (size, transfer time, links to report/summary).
- Trace form: kind kdebug or kernel profiler, name, seconds; kdebug: mode, filter f/none, quiet; profiler: target,
  Hz. One Start/Stop button, plus abort. The form offers `mode=stream`, but the daemon refuses it: leave it on buffer.
- Picking a profiler target: sort Processes by CPU % or wakeups/s, click the suspect, set seconds (5-10) and Hz
  (1000), Start. Needs USB (the poke goes to 192.168.7.2:5141).

## 6. Recipes

### 6.1 Why is it hot
1. Read now.json: `hot`, `temp.max`, `thermal.level`, `procs.by_cpu[:5]`, `procs.by_wakeups[:5]`, `gpu.owners`,
   `klog.top_tags`, `crashes`. Sum `cpu.busy` for the idle CPU sum (8 cores x 100 %).
2. A userland process on top: `phone /var/local/bin/pstack PID` a few times (it prints the shared-cache slide),
   then symbolize the addresses on the phone with `phone /var/local/bin/a2s ADDR...` (or `tools/pstack-sym.py`).
   Its own log: `phone /var/local/bin/oslog -t 10 PROCNAME` (always bounded with -t).
3. Wakeups (kernel_task or a daemon with thousands/s, low CPU): `mon trace wake1 kdebug 5 filter=none`, then
   `mon wait 60`, then read `report.txt` / `summary.json`, or run sweet-trace.py on `trace.swtr`.
4. Where a process spends kernel/CPU time: `mon trace NAME prof 10 target=PROC` (recipe 6.2, USB only).
5. Fix in userland first (launchd.plist edit, moving bad data aside), with a backup and a KNOWN-GOOD.txt line, and
   watch the same now.json fields drop. Record switched-off services in `docs/redfin/disabled-services.md`.
6. These are all read-only on the phone and don't need sweetmon's client slot, so they work while the collector runs.

### 6.2 Profile one process (kernel profiler, USB only)
`mon trace bb prof 10 target=backboardd hz=1000 kernel=builds/xnu/<kernel dir>/kernel.development.sweet.gz`, then
`mon wait 60`. The collector pokes `p prof start backboardd 1000 10`, waits for `SWEET PROF: start`, then reads the
buffer (`pmem PA LEN`) and runs sweet-prof.py. Result: `report.txt` + `prof.folded`. Fails with "no SWEET PROF:
start line 15 s after the poke" when USB (poke port 5141) isn't reachable.

### 6.3 Frame pacing trace
1. Quick look: `mon frames on`, wait a few samples, read now.json `frames` (fps, vsync count, gpu_ms_p50/p90,
   present_to_shown_ms_p50). Idle shows ~90 Hz vsync. `mon frames off` when done (kdebug on costs a little everywhere).
2. Full chain: user starts the interaction (scroll in Preferences, etc.), then `mon trace fp1 kdebug 8 app=Preferences`
   (filter f is the frame chain), `mon wait 60`; read `summary.json` (frames, stage_gaps_ms, largest_gap_counts).
   A trace started while frames mode is on takes kdebug over; frames mode resumes after it.

### 6.4 Is my change cheaper (A/B)
1. Note the time, take ~60 s of baseline with the old setting, flip the toggle (sysctl, `files put` + restart, plist),
   take ~60 s more. Don't reboot in between if you can avoid it.
2. Compare from the metrics file on the PC:
```
python3 - <<'E'
import json,statistics as S
rows=[json.loads(l) for l in open('logs/mon/metrics-20261029.jsonl')]
def win(a,b):
    r=[x for x in rows if a<=x['t']<b and x.get('busy')]
    return dict(n=len(r),cpu=round(S.mean(sum(c or 0 for c in x['busy']) for x in r),1),
                tmax=round(S.mean(x['temp']['max'] for x in r if x.get('temp')),1),
                self_ms=round(S.mean(x['self_ms'] or 0 for x in r),2))
print('A',win(T0,T1)); print('B',win(T1,T2))   # T0..T2: unix seconds
E
```
3. Per process: the `top` field of the rows, or several now.json reads. Temperatures lag minutes; CPU sum and
   wakeups react in seconds, so judge by those first.

### 6.5 After a reboot
1. Wait for "phone answers" (cycle does this). The collector reconnects every 2 s; if 5150 is closed it starts
   `sweetmon -D` over ssh within ~30 s. A new `klog-<boot>.txt` starts.
2. `mon-status` should say connected and klog `ok (0x... from ...)`. If the daemon isn't there at all (new rootfs,
   file lost): `mon install`.
3. Re-apply runtime settings that don't survive a reboot (e.g. the USB fast-path sysctls in section 10).

### 6.6 New kernel: KLOG_PA changed
The ring address comes from, in order: config.json `klog_pa` (set by `mon klog-pa`), the daemon's hello (null until a
`klog PA` was accepted), the `Kernel:` line in KNOWN-GOOD.txt -> that folder's `KLOG_PA.txt`, the built-in
`0x101d0ef08` (r63a). A test kernel that isn't in KNOWN-GOOD.txt with a different PA: read
`builds/xnu/<dir>/KLOG_PA.txt` and send `mon klog-pa 0x...`. The daemon checks the address (total <= 2^40,
printable text at the end of the ring) and refuses a wrong one. After going back to the known-good kernel:
`mon klog-pa auto`. Check `klog.status` in now.json.

## 7. Overhead and rules

| Setting / action | Phone cost (measured 2026-10-29) |
|---|---|
| default `rate 1000 2` (process table every 2nd sample) | **3.8 ms/s** daemon CPU (0.7 ms/s without the table, 7 ms/s with it every sample) |
| `rate 200 1` | ~32 ms/s |
| klog start | full 730 KB ring dump in ~1.5 s, then increments every 5 s |
| 8 s kdebug trace | 19.6 MB raw / 4.3 MB lz4 |
| 5 s kdebug trace | 11.9 MB / 2.6 MB, sent in 1.5 s; daemon cpu_ms ~720; parses with sweet-trace.py --summary-json |
| USB link (old path) | 1.23 MB/s, 2 ms ping |
| Wi-Fi link | 0.8 MB/s, ~42 ms ping, and wland uses ~3x its idle CPU while streaming |
| frames mode | sees ~90 Hz vsync; small kdebug cost everywhere while on |

Rules:
- Stay at `rate 1000` except for short, deliberate high-rate windows. Watch `self.cpu_ms_s`.
- **One client at a time.** A new authenticated client replaces the old one and **aborts its trace**. Agents and
  scripts use `mon ...` or the collector API, never connect to 5150 themselves (no sweetmon-client.py while the
  collector runs). Phone-side read-only tools (pstack, a2s, oslog, psx, sctl) don't touch the slot.
- Traces use buffer mode: nothing is sent while recording, the whole trace after stop.
- **kdebug has a single owner.** Don't run the old `sweettrace`, `fpsbench`/`exp` runner traces or anything else
  using ktrace while frames mode is on or a sweetmon trace runs (EBUSY, or one steals the other's data). `mon frames
  off` first. The daemon always releases kdebug on stop, abort, client loss and exit.
- USB is the default; auto picks the link with the faster measured speed test and falls back to the other one.

## 8. Known limits and bugs

- `mode=stream` is refused by the daemon (v1 is buffer only), though README/dashboard/fakephone still offer it.
- A trace is lost if the client disconnects (link drop, link switch, collector restart, a second client): the daemon
  aborts it. Don't switch links or restart the collector during a trace.
- `self.klog_bps` (bytes/s the daemon sent as klog) is unreliable and often 0 (also read 337 once): use
  `klog.bps_kernel` / `klog.bps_rx`.
- hello `klog_pa` is null until a `klog PA` was accepted on that connection (so phone.json `last_hello.klog_pa` is
  null after a fresh daemon start); it isn't a fault.
- Not started at boot by launchd; it relies on the collector's ssh start (or `mon install`).
- Wi-Fi is slower than USB and loads wland; prof traces need USB regardless.
- `mon speed` on a slow link can answer "no reply from the phone": a ping reply arrives before the speed reply and
  the collector resolves the wrong pending command. The real result is in collector.log as `unsolicited reply
  {'cmd': 'speed', ... 'mbps': ...}`. A fix is coming.
- `phone.nproc` / `procs.nproc` are null in current samples.
- Agent requests are serial: long `mon wait`/`mon speed` calls block the agent for everyone.

## 9. Troubleshooting

| Symptom | Check / fix |
|---|---|
| `collector not answering at http://127.0.0.1:8765 ...: mon-start` | collector died: `mon-start`, read collector.log |
| `mon-status`: not connected, "starting the daemon on HOST over ssh" repeating | ssh works, daemon fails: `phone ls -l /var/local/bin/sweetmon /var/local/sweetmon.key`; `mon install` |
| connected but `not authed` / auth error | key mismatch between agent/sweetmon.key and the phone: `mon install` re-copies it (don't print either) |
| klog status not ok / klog file not growing | wrong PA for this kernel: recipe 6.6 |
| now.json `stale: true` or `t` old | link down: phone rebooting, USB gone (`status`), Wi-Fi address changed (`--wifi-host`) |
| trace `failed`: "no trace data N s after the start" | daemon lost kdebug (another owner) or crashed: `mon cmd info` (kdebug_owner), check for sweettrace |
| trace `failed`: "transfer stalled" / "got X of Y bytes" | link dropped mid-transfer; repeat on USB |
| trace done but report.txt says analyzer error | run sweet-trace.py by hand on trace.swtr; the .swtr is fine |
| prof: "no SWEET PROF: start line" | USB down or the kernel lacks the profiler; poke works only over USB |
| dashboard empty, API fine | browser tab stuck on old SSE: reload |

## 10. Today's findings (2026-10-29), a worked example

- **vmd** (Visual Voicemail) looped on CoreTelephony (no CommCenter), ~1 core, footprint 219 -> 912 MB, ~100k log
  lines. Stopped: job removed from /System/Library/xpc/launchd.plist (backup `launchd.plist.before-vmd`). See
  `docs/redfin/disabled-services.md`.
- **dasd / coreduetd / biomed**: Biome widget stream with 1970 timestamps (no wall clock for the first ~238 s of
  each boot) made dasd walk back 56 years in 2-h steps, about 1 core. Stream moved aside
  (`_DKEvent.Dasd.WidgetView.heat-bak`), daemons restarted; r64u adds `sweetrtcoff` so the date is right from boot.
- Result: idle CPU sum 255 % -> 115 % -> 39 % -> ~10 % of a core; temperature 73 -> 54 °C.
- How the heat agent worked: `phone /var/local/bin/pstack PID` + `a2s` symbols, bounded `oslog` captures,
  sweettrace kdebug traces for wakeups, all read-only while the collector held sweetmon's client slot.
- Remaining leads: kernel delay()-polling threads at ~1,800 wakeups/s (kernel_task shows 3,500-3,800/s in now.json);
  the metal2vulkan fence spin-wait while rendering (~0.36 core); wifip2pd respawning every 10 s.
- Seen once, unexplained: MediaRemoteUI sig 5 crash during a speed test; a 4 s all-cores burst at idle.

## 11. USB fast path (kernel 1034, image r64u) — results

**Promoted 2026-10-29 (user decision): r64u is the KNOWN-GOOD image** (sha256 8df336ee39dff4df…); fallback r63a, then
r62b. `agent/cycle-base.txt` = `r64u`, so new cycles inherit its cmdline (with `sweetrtcoff`).

- **r64u** = r63a + kernel patch **1034** (branch `ws-z-usbfast` ce6a61b, kernel `builds/xnu/ce6a61b5…-ce6a61b5ed`,
  klog PA unchanged **0x101d0ef08**) + `sweetrtcoff=1792779327` (date correct from boot), minus `,mediaserverd` in
  sweetnull and minus `sweetbtlog=1` (cmdline limit 591 bytes, now 584). Booted first try in 76 s.
- Runtime sysctls, default 0 = old path: `kern.sweet_usb_poll_us` (50..1000), `kern.sweet_usb_txbatch` (2..16).
  Counters: `kern.sweet_usb_tx_frames`, `kern.sweet_usb_tx_xfers`, `kern.sweet_usb_tx_drops`,
  `kern.sweet_usb_rx_frames`. Boot-args `sweetusbpollus` / `sweetusbtxb` exist, but the cmdline has no room yet.
- Syntax on the phone: `/var/local/bin/sctl NAME VALUE` (a space, **not** `=`).
- 32 MiB `mon speed`:

| Setting | MB/s |
|---|---|
| old path (both 0) | 1.2 |
| poll 200 | 4.9 |
| poll 200 + txbatch 8 | 12.8 |
| poll 200 + txbatch 16 | 12.8 |
| **poll 100 + txbatch 16** | **28** (5.7-6.6 frames per transfer; phone CPU 255 ms per 32 MiB vs 776 on the old path; no extra idle CPU) |

- A 20 s kdebug trace moved 2.48 MB in 0.1 s (39 MB/s). Live log, poke and the command server work.
- The kernel default stays 0/0 (old path). The **collector applies poll_us 100 / txbatch 16 over ssh on every connect**
  (logs/mon/config.json `usb_fast`; `null` = leave alone) and shows the values in `mon snap` / the dashboard. If that
  isn't in place (older collector, or ssh down), apply by hand:
  `phone /var/local/bin/sctl kern.sweet_usb_poll_us 100` and `phone /var/local/bin/sctl kern.sweet_usb_txbatch 16`.
  Then `mon speed 32` once so auto learns the new USB speed (Wi-Fi stays ~0.8 MB/s).
- Next step for the kernel: make 100/16 the built-in default once it has soaked (keep the sysctls to switch back).
- With the fast path, a USB speed test is no longer a long blocking request; on the old path a 32 MiB test takes ~27 s.
