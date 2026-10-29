# redfin: state at the end of 2026-10-29 (evening session: monitoring, heat, USB speed)

Read this first in a new chat; it supersedes redfin-status-2026-10-29-final.md. Pixel 5 (redfin) on iOS 16.7 / SWEET
XNU. Repo github.com/DenialOfGravity/ios-redfin, integration branch `redfin-int` (= r64u's kernel source + sweetmon).
Monitoring and traces: **claude/redfin-sweetmon-guide.md** (repo docs/redfin/sweetmon-guide.md).

## Known good

| Part | Version | Where |
|---|---|---|
| Image | **r64u** (RAM only: `to-fastboot`, `boot r64u`), sha256 8df336ee39dff4df99f0dd0afc037da5320ba11d410806de5d9bfd3e8007dfb6 | PC folder r64u/ |
| Kernel | r63a's xnu tree (ws-y-ram aca60f4) + **1034** USB fast path = branch `ws-z-usbfast` ce6a61b, merged in redfin-int c4e5996; klog PA **0x101d0ef08** | builds/xnu/ce6a61b5edfd7c69550d55f1798442891cf15c89-ce6a61b5ed |
| Cmdline | r64u/r64u.cmdline (584 of 591 bytes): r63a's + `sweetrtcoff=1792779327`, minus `,mediaserverd` in sweetnull and `sweetbtlog=1` | |
| Base for cycles | `agent/cycle-base.txt` = **r64u** (was ram62b), so new images inherit the cmdline above | |
| Daemons / Metal | unchanged from r63a: btd 43320fd, wland 1363de7, sensd 3b82505, SweetMetal2 rotfb4 763f2e4 | /var/local/bin/*.knowngood |
| sweetmon | phone daemon ws-z-mon 645854a (/var/local/bin/sweetmon, key /var/local/sweetmon.key); PC collector + dashboard ws-z-mon ef9260f (tools-claude/sweetmon/) | dashboard http://localhost:8765 |

Fallbacks: r63a (no USB fast path, no sweetrtcoff), then r62b. The user confirmed Wi-Fi, BT audio and camera on r64u.

## New today
- **sweetmon** (live monitor): phone daemon samples per-core CPU, temps, memory, top processes by CPU and wakeups
  (~4 ms/s, <1% of a core), tails the kernel log ring from /dev/pmem, records kdebug traces in RAM and sends them
  LZ4-compressed. The collector (auto-started by the phone agent) writes logs/mon/now.json every second,
  logs/mon/klog-<boot>.txt (replaces `klog PA` pulls), metrics jsonl and logs/traces/NAME-time/ (auto-analysed with
  sweet-trace.py). Dashboard with Start/Stop trace buttons. Claude: `mon snap`, `mon trace NAME kdebug|prof SECS`,
  `mon stop`, `mon speed`, `mon usb-fast`, ... One client at a time: agents go through `mon`, never port 5150.
- **USB Ethernet fast path (1034)**: 1.2 -> **~27-28 MB/s** (traces ~39 MB/s), less phone CPU per MB, no idle cost.
  Kernel default stays 0/0; the collector sets `kern.sweet_usb_poll_us 100` + `kern.sweet_usb_txbatch 16` on every
  connect (config.json `usb_fast`). Wi-Fi measured slower (0.8 MB/s, ~42 ms ping): USB stays the default link.
- **Heat**: idle CPU sum ~255% -> ~10%, max temp ~73 -> ~54 °C, battery drain -400 -> ~-90 mA.
  - vmd (Visual Voicemail) looped on missing CoreTelephony (~1 core, memory to 900 MB): job removed from
    launchd.plist (backup .before-vmd). **Revisit with telephony** (docs/redfin/disabled-services.md).
  - dasd/coreduetd/biomed (~1 core): no wall clock for the first ~238 s of each boot wrote 1970 events into Biome;
    dasd's widget-budget predictor walked back 56 years. Stream moved aside (`_DKEvent.Dasd.WidgetView.heat-bak`,
    PC backup tmp-heat/widgetview.tar); r64u's `sweetrtcoff` prevents new 1970 data.

## Open issues / next
1. Kernel wakeups ~3,500/s (kernel_task): two delay()-polling kernel threads (thread-call IOTimerEventSource ~87/s with
   ~10 IODelays each, and tid 0x3d8 every ~1.1 ms); owner driver not identified (heat agent traces tmp-heat/tr2, tr3).
2. metal2vulkan fence spin-wait while rendering (~0.36 core, backboardd `metal2vulkan-queue-wait-0`): make it a
   blocking wait (userland, no reboot).
3. wifip2pd respawns every 10 s (sandbox check fails): optional launchd removal; check wifid doesn't need it.
4. Make 1034's 100/16 the kernel default after a soak; cmdline has no room for the boot-args.
5. Seen once on r64u: MediaRemoteUI sig 5 during a speed test; a 4 s all-core burst at idle (unexplained).
6. Carried over from r63a: Wi-Fi auto-join below-RSSI refusal; no Wi-Fi bars (1014 resets); landscape speed;
   unused low ~950 MB RAM; no charging under iOS (charge in fastboot; no automatic return to fastboot).
7. sweetmon limits: stream trace mode refused (buffer only); a trace is lost if its client disconnects; daemon not in
   launchd (collector starts it over ssh); `self.klog_bps`/`nproc` fields unreliable.

## Notes
- Phone `sctl` syntax: `sctl NAME VALUE` (space).
- RTC offset 1792779327 measured this boot; drift not measured (tools/flame-rtc.py).
- KNOWN-GOOD.txt lists every phone-side change of today with its revert.
