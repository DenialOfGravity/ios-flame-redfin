# sweetmon: live monitor and one-button traces for redfin

What runs where (design and wire protocol: `docs/redfin/sweetmon.md` on branch ws-z-mon):

| Piece | Where | What it does |
|---|---|---|
| `sweetmon` daemon | phone, `/var/local/bin/sweetmon -D`, TCP 5150 | samples, kernel log tail, traces in RAM; one client |
| `collector.py` | WSL, this folder | connects to the phone, writes `logs/mon/` and `logs/traces/`, serves the dashboard |
| `dashboard.html` | browser, http://localhost:8765/ | live charts, process table, klog tail, trace buttons |
| `phone-agent.sh` `mon ...` | WSL agent | Claude's hook (see below) |
| `fakephone.py`, `e2e-test.sh` | tests | a fake daemon and the end-to-end test of the collector |
| `lz4py.py` | this folder | fallback LZ4 decoder (copy of the repo's tools/lz4py.py) |

## Start it and open it

The phone agent starts the collector by itself, both when the agent starts and when the phone's USB network comes up.
Wi-Fi works too: once the collector has seen the phone over USB, it remembers the phone's Wi-Fi address.
To start it by hand in WSL:

    python3 /mnt/c/ClaudeProjects/iOS_Pixel5/tools-claude/sweetmon/collector.py

Then open **http://localhost:8765/** in a Windows browser. WSL2 forwards localhost to Windows by default.

If the page does not open:
1. Check that the collector runs: `ask NAME mon-status`, or look at `logs/mon/collector.log`.
2. If WSL localhost forwarding is off (`localhostForwarding=false` in `%UserProfile%\.wslconfig`, or mirrored
   networking misbehaving), start the collector with `--http-host 0.0.0.0`. Then open `http://<WSL address>:8765/`
   (`hostname -I` in WSL gives the address). That port is then also reachable from your LAN, so only do this on a
   trusted network.
3. Without a browser: `logs/mon/now.json` holds the same data as text, and so does `mon snap`.

First time only: `collector.py --make-key` writes `agent/sweetmon.key` (the agent does this by itself). Then
`ask NAME "mon install"` copies the daemon and the key to the phone and starts it. Keep the key out of git.

## The dashboard

- **Header:** link (USB or Wi-Fi) with ping time, phone uptime, battery % and current (negative = discharging),
  hottest sensor, thermal level, average CPU, GPU busy, and **sweetmon cost**. Sweetmon cost is the daemon's own CPU
  time in ms per second, with % of one core and its memory. About 4 ms/s is normal at the default rate (1000 ms,
  process table every 2nd sample).
- **Link selector:** `auto` uses the link with the faster speed test and falls back to the other one. With no speed
  test yet, it uses USB first. Each button shows that link's last measured MB/s; a star marks the one auto prefers.
  **Speed test** sends N MiB from the phone over the current link and saves the result for that link in
  `logs/mon/phone.json`. Run it once on each link to teach auto.
- **Window:** how much history the charts show (1, 5 or 15 min). The collector keeps 1 hour in memory.
- **Hot line** (under the header): the collector's short answer to "what is making it hot or slow". It lists the
  hottest sensors, thermal caps, busy cores, top CPU users, top wakeup sources, GPU owners, a noisy kernel log, heavy
  battery drain, sweetmon's own cost and recent crashes.
- **CPU busy per core:** % busy per core in each sample. cpu0-5 are silver (A55), cpu6 is gold, cpu7 is prime (A76).
- **Cluster clocks:** MHz per cluster, from the kernel's 5 s `SWEET CPUFREQ` line.
- **Temperatures:** the `kern.sweet_temp_*` sysctls, in degrees C (or from the `SWEET THERMAL` klog line if the
  sysctls are missing).
- **GPU:** busy % per 5 s and the owners table (submits and GPU ms per process), from the `SWEET GPU: 5s:` line.
- **Memory:** used, free and compressed MB, plus wired, active, inactive, page-ins/s, faults/s and process count.
- **Frames:** fps shown on screen (from the `SWEET FB: 5s` line). Turning on *light frame mode* enables kdebug frame
  events in the daemon (a small cost everywhere) and adds the measured fps and GPU and present-to-shown times.
- **Processes:** the top 15 by CPU %, with wakeups/s, memory, threads and disk KB/s. Click a column to sort. Click a
  row to make it the kernel profiler's target.
- **Kernel log rate:** bytes/s the kernel writes, and the top tags of the last 60 s. A tag is the `SWEET XXX` prefix
  or the first word of the line. Click a tag to filter the log by it.
- **Kernel log:** a live tail with a regex filter, pause and clear. The whole log is in `logs/mon/klog-<boot>.txt`.
- **Trace:**
  - kind *kdebug* runs sweettrace in the daemon. Mode *buffer* sends the trace after stop (no load on the link while
    it records); *stream* sends it while it records. Filter *f* keeps only the frame chain; *none* keeps everything.
    *quiet* pauses sampling while it records.
  - kind *kernel profiler* pokes `p prof start TARGET HZ SECS` over USB, waits for the `SWEET PROF` lines, then reads
    the buffer with `pmem`.
  - Start and Stop share one button. The status line shows recording seconds, transfer MB/s and the analyzing step.
    The list below has every trace with its size, transfer time and links to its report and summary.

## How Claude uses it

Agent actions (`agent/inbox/NAME.req`):

    mon-start | mon-stop | mon-status          the collector process
    mon snap                                   text summary of now.json (hot line, temps, CPU, GPU, top processes, klog)
    mon trace NAME [kdebug|prof] [SECS] [k=v]  start a trace (k=v: mode=stream filter=none quiet=1 app=Preferences;
                                               prof: target=backboardd hz=1000 kernel=builds/xnu/<dir>/kernel...gz)
    mon wait [SECS]                            wait for the running trace to finish, print its meta
    mon stop | mon traces                      stop the trace / list traces
    mon link usb|wifi|auto | mon speed [MB]    link choice / speed test (teaches auto)
    mon frames on|off | mon rate MS            light frame mode / sample period
    mon klog-pa PA | mon klog-pa auto          the kernel log ring address (default: the KNOWN-GOOD kernel's KLOG_PA.txt,
                                               then 0x101d0ef08 of r63a)
    mon install                                daemon + key onto the phone, start it

Files (all under the project folder):

- `logs/mon/now.json`: the latest merged snapshot, rewritten atomically every sample. Read this directly instead of
  pulling anything from the phone. Key fields: `hot` (the explanation lines), `cpu.busy` / `cpu.clusters`, `temp`,
  `thermal`, `battery`, `gpu.owners`, `procs.by_cpu` / `by_wakeups`, `klog.top_tags`, `self.cpu_ms_s`, `link`,
  `crashes`, `trace`. `stale: true` means the link is down and the values are the last ones received.
- `logs/mon/klog-<boottime>.txt`: the full kernel log of that boot. It is gap-filled after reconnects, and a
  `[sweetmon: N bytes of kernel log lost here]` marker shows where the ring overran while disconnected. This
  replaces `klog PA` pulls.
- `logs/mon/metrics-YYYYMMDD.jsonl`: one compact line per sample (for later plots).
- `logs/traces/NAME-MMDD-HHMMSS/`: `trace.swtr` (or `prof.bin`), `meta.json` (sizes, MB/s, phone-side
  counters), `summary.json` (`sweet-trace.py --summary-json`), `report.txt` (the analyzer output), and
  `prof.folded` for profiler traces.
- `logs/mon/collector.log`, `config.json` (link, rate, frames, klog_pa), `phone.json` (Wi-Fi address and per-link
  speed), `state.json` (klog position, for gap fill across collector restarts).

HTTP API (127.0.0.1:8765):

- GET: `/api/now`, `/api/status`, `/api/history?secs=N`, `/api/klog?n=N&grep=RE`, `/api/traces`,
  `/api/traces/DIR/{summary.json,report.txt,meta.json,prof.folded}`, and `/api/stream` (SSE events: init, sample,
  klog, link, hello, trace, speed, frames).
- POST (JSON): `/api/trace/start {kind,name,secs,opts}`, `/api/trace/stop {abort}`, `/api/cmd {cmd}`,
  `/api/link {link}`, `/api/speed {mb}`, `/api/frames {on}`, `/api/klog-pa {pa}`, `/api/rate {ms}`.

## Test without the phone

    bash tools-claude/sweetmon/e2e-test.sh SMALL.swtr     (TOOLS=dir with sweet-trace.py and sweet-prof.py)

The test runs the fake daemon on 127.0.0.2 (USB) and 127.0.0.3 (Wi-Fi). It checks connect and auth, samples into
now.json, klog gap fill, ring overrun, both trace modes (byte-identical to the source), abort, the profiler path,
speed test, frames, klog-pa, link switching (including auto by speed), a wrong key and a phone reboot, and calls
every API endpoint.
