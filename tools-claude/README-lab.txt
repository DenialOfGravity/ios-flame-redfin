u-lab: fast A/B experiments on the phone with no LLM in the loop (branch ws-u-lab, 2026-10-28)
==========================================================================================

What changed
------------
1. sweettrace (phone/tools/sweettrace.c, userland build of ws-u-lab)
     -f            keep only what swtr-reduce.py keeps (backboardd, SpringBoard, Preferences frame chain); byte-identical
                   to `swtr-reduce.py FULL OUT` (checked with cmp on o2-base-set / o2-base-pg). -F P1,P2: other processes.
                   Events no rule can keep are dropped while reading (1/3 of the memory).
     -z / -Z N     gzip the output (zlib level 6 / N). `gzip -dc` gives the same .swtr format the PC tools read.
   Size of an 8 s Settings fling trace: 180 MB full -> 52 MB with -f -> ~4.5 MB with -f -z (gzip 6; 5.4 MB at -Z 1).
   With the kernel file server's 1.3 MB/s that is ~4 s instead of 2-2.5 min; over ssh it is usually faster still.
   Without -f/-z sweettrace behaves exactly as before.
2. phone agent (tools-claude/phone-agent.sh.new; the coordinator swaps it in and runs `ask NAME reload`). New actions:
     pull REMOTE LOCAL [gunzip]    ssh `cat` of a phone file into the project folder, size checked against the
                                   phone's `toybox stat`, kernel file server as the fallback; prints MB/s.
                                   gunzip: also writes LOCAL minus .gz, decompressed.
                                   e.g.  pull /var/tmp/x.swtr.gz logs/x.swtr.gz gunzip
     exp PLAN                      starts tools-claude/exp-run.py PLAN in the background (PLAN in the project folder)
     exp-status                    alive?, the last 25 log lines, the A/B table when finished
     exp-stop / exp-kill           stop after the current step (the env is restored) / kill at once (env NOT restored)
     mkimage NAME KDIR [BASE] [CMDLINE_FILE]   local boot image (see 5)
   All old actions are unchanged.
3. tools-claude/exp-run.py + tools-claude/labtrace.sh: the experiment runner (below).
4. Live frontend knobs (metal2 build of ws-u-lab = ws-u-gpudraw + one commit, d9a9c25, cherry-pickable onto any metal2
   branch): /var/local/mtl2-live (KEY=VALUE) is checked once a second from -commit and overrides the env for
     SWEET_CPUFAST, SWEET_ENCSTAT, SWEET_FNSTAT, SWEET_ENC_SLOW_MS
   with no backboardd restart (log line "native-metal: live: ..."). A key left out = its env value; an empty file = all
   env values. Everything else (TU_DEBUG, SWEET_UBWC, SWEET_TIMELINE, SWEET_PREWARM, SWEET_FLUSH, SWEET_SHADOW_SEED,
   SWEET_RENDER_QOS/PRI, the bridge's and Turnip's knobs) is read once at device/pipeline/thread setup: restart needed.
5. tools-claude/mkimage.py: NAME/redfin-NAME.img = BASE (default r47a) with KDIR's kernel, made in WSL in ~10 s.
   Kept from BASE: boot header, shim, ADT (GPU firmware, poke script), payload cmdline (or CMDLINE_FILE's first line),
   AVB footer parameters including the salt. Writes NAME/redfin-NAME.img, .sha256, NAME.cmdline, mkpayload.log,
   README.txt (base, kernel sha256, KLOG_PA, compiler, tool versions). Refuses an existing NAME, a KDIR without
   COMPILER.txt, with DO-NOT-BOOT.txt or whose build.log lacks "ISA check ok", a kernel that does not match SHA256SUMS.
   Regression check (same kernel -> same image, byte for byte):
     t47  = builds/xnu/7ccc83f4...-7ccc83f401 on r47a  -> 676f40b4693966e7...  = r47a
     t46  = builds/xnu/f895b195...-f895b195a5 on r46a  -> ce99ae83a4c1745b...  = r46a
     t53b = builds/xnu/04730b01...-04730b0193 on r47a  -> 597e647717e5b01a...  = r53a (the cloud-made image)
   Tools: ~/redfin-build/tools/{mkbootimg,avb} (git clone --depth 1 of LineageOS android_system_tools_mkbootimg /
   android_external_avb on first use), else tools-claude/vendor/{mkbootimg,avb} (vendored copies of the same commits).
   mkpayload.py + adt.py from $REPO/tools (the agent's repo checkout). Only images named r... can be booted with `boot`.
   Usage:  ask lab-1 "mkimage r54a builds/xnu/<sha>-<sha10>"        (base r47a, its cmdline)
           ask lab-2 "mkimage r54b builds/xnu/<sha>-<sha10> r47a agent/tmp/my.cmdline"

Switching over (operator / coordinator)
---------------------------------------
a. sweettrace: the userland build of ws-u-lab -> builds/userland/ws-u-lab-<sha10>/sweettrace, then
     files get /var/local/bin/sweettrace /mnt/c/ClaudeProjects/iOS_Pixel5/backup-sweettrace.pre-lab   (old binary)
     files put /mnt/c/ClaudeProjects/iOS_Pixel5/builds/userland/ws-u-lab-<sha10>/sweettrace /var/local/bin/sweettrace 755
   Check: phone "/var/local/bin/sweettrace -h"  must list "[-f | -F PROCS] [-z | -Z LEVEL]".
   exp-run.py also works with the old binary (it notices, takes full traces and reduces them on the PC; slower).
b. phone agent: cp tools-claude/phone-agent.sh.new tools-claude/phone-agent.sh (keep a .bak), then `ask NAME reload`.
c. Live knobs (optional): install the metal2 build of ws-u-lab like any SweetMetal2 bundle, or cherry-pick d9a9c25
   onto the branch under test. Without it, plan `live` lines do nothing (the runner warns: live_ok 0).

Experiment runner
-----------------
Write a plan (e.g. agent/exp/ubwc.plan; template agent/exp/example.plan):

    name ubwc                 # output logs/exp-ubwc-MMDD-HHMM/
    scenes settings pages     # settings | pages | scroll | idle
    repeats 3                 # rounds
    order abba                # A B B A A B (default) | abab | blocks
    restart always            # fresh backboardd for every run (default) | switch: only when the env changes
    base
      TU_DEBUG=gmem
      SWEET_TIMELINE=1
    variant A
      SWEET_UBWC=1
    variant B
      SWEET_UBWC=0
      -TU_DEBUG               # "-KEY" drops a base line
    # optional: settle 4, hot 62, cool 57, stop_battery 25, trace -t 8, keep_swtr no, restore yes,
    #           settings_xy 914 290, settings_wait 3, app Preferences, nav <poke> (scroll scene), live KEY=V (in a variant)

Run it:   ask lab-1 "exp agent/exp/ubwc.plan"      then   ask lab-2 "exp-status"  (every few minutes, or not at all:
          the A/B table lands in logs/exp-ubwc-*/ab.txt and is printed by exp-status when done)
By hand in WSL: python3 tools-claude/exp-run.py agent/exp/ubwc.plan [--dry-run]
Recompute the tables later: python3 tools-claude/exp-run.py --analyze-only logs/exp-ubwc-XXXX [PLAN]

Per run the runner (WSL, the agent's ssh key, direct UDP pokes to 5141, the agent's live log logs/live-*.txt):
  - writes /var/local/mtl2-env (base + variant; read back and compared), psx -k backboardd, then waits for
    backboardd's "native-metal: prewarm: N pipelines in X ms" and SpringBoard's prewarm line in the live log (no fixed
    sleeps; 120 s timeout), checks backboardd's "env K=V" lines against the plan (env_ok), settles 4 s;
  - guards: newest SWEET THERMAL line (max of silver/gold/prime/cpuss/gpu) >= hot -> pause until <= cool (stop after
    15 min); SWEET BATTERY shown <= stop_battery -> stop (park the phone in fastboot to charge); display: keep-alive tap
    540 40, `p disp`, the power key (key 0) only when the display is off, then the unlock swipe and home x2;
  - scene: settings = psx -k Preferences, home x2, page 2, tap 914 290, wait 3 s, check psx (one retry);
    pages = home x2; scroll = the plan's nav pokes; idle = nothing;
  - trace: /var/tmp/labtrace.sh (copied from tools-claude/labtrace.sh at start) = sweettrace -t 8 -d 1 -f -z plus the
    scene's flings sent on the phone (same timing as flingtrace2.sh);
  - pull over ssh (ControlMaster: one connection for the whole experiment), size check, removed on the phone;
  - analysis in the background while the phone goes on: gunzip, sweet-trace.py --summary-json, frames-export.py;
  - a STOP file in the output dir (exp-stop) ends it after the current step; any stop restores the original
    mtl2-env (restore no: leaves the last variant) and restarts backboardd.
Output logs/exp-NAME-MMDD-HHMM/: run.log (every step with timestamps), plan.txt, mtl2-env.orig, lab-ID.swtr.gz,
ID-report.txt, ID.json (summary-json), frames-ID.json, summary.tsv (one row per trace: temperature, battery, prewarm,
env_ok, sizes/times, frames, fps, interval p50/p90/mean, vsync histogram (all / swipes), GPU p50/p90, stage medians,
display-thread on-CPU, root-cause counts) and ab.txt (medians per variant and scene, difference to the first variant
with %, + better / - worse, and the min..max range per variant so the noise is visible).

Expected time: per trace ~25 s (restart 5-25 s when the env changes, navigation ~8 s, trace 9.5 s + ~2 s gzip,
pull ~5 MB in 1-4 s); analysis overlaps. A 2-variant x 2-scene round ~2-2.5 min; repeats 3 (12 traces) ~8 min with
no LLM round-trips (was 12-15 min per single A/B pair). Live-knob variants with `restart switch` save the restart.

Mocked test (container): the full runner loop against a fake phone (fake ssh, live log, a real reduced trace)
reproduced the existing o2-base-set summary numbers; nothing of it has run on the real phone yet.
