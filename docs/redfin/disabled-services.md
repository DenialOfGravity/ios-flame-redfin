# redfin: iOS services switched off on the phone (revisit when the feature they need is ported)

Each entry: what, why, how it was switched off, how to undo. The phone-side backups are listed in the PC's KNOWN-GOOD.txt.

| Service | Off since | Revisit with | Why | How | Undo |
|---|---|---|---|---|---|
| **vmd** (Visual Voicemail, `com.apple.voicemail.vmd`, /System/Library/PrivateFrameworks/VisualVoicemail.framework/vmd) | 2026-10-29 (r63a) | **telephony** (CommCenter / CoreTelephony, modem) | No CommCenter: vmd retried `com.apple.commcenter.coretelephony.xpc` in a tight loop (Code=4099 "connection invalidated"), ~1 full core, footprint 219 MB -> 912 MB in ~20 min, ~100k os_log lines (also loading logd). Found with sweetmon (docs/redfin/sweetmon.md). Idle CPU sum went ~255% -> ~122% of a core. | Job removed from /System/Library/xpc/launchd.plist (on-demand job: MachServices + CTTelephonyCenter / notifyd launch events, no KeepAlive); the job dict kept as /System/Library/xpc/com.apple.voicemail.vmd.job.plist.disabled. The running process was paused with SIGSTOP until the next reboot (no launchctl on the phone). | `cp -p /System/Library/xpc/launchd.plist.before-vmd /System/Library/xpc/launchd.plist` (mode 644), reboot. Or put the job dict back under LaunchDaemons with plistlib. |
| fairplayd (`com.apple.fairplayd.H2`) | earlier (quickwins) | DRM / App Store | relaunch loop + locationd deadlock (tools-claude/quickwins-launchd.py --no-fairplayd) | job removed | launchd.plist.before-quickwins |
| AegirPoster (lock-screen poster extension) | 2026-10-28 | wallpaper / poster work | idle 70 -> 52 °C | .appex renamed | logs/aegir-disable.txt |

When telephony work starts: restore vmd first and check it no longer loops once CommCenter answers.
