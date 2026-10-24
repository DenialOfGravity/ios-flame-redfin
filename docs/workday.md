
## [13:50] Wi-Fi join — Phase 1 (diff vs Linux ath10k): 3 fixes, same crash
- Fixed vs ath10k: pdev chain mask 0x3 from rf chains (INIT says 0x7), pmf/dynamic-bw/idle-ps/ani pdev params,
  resource config back to ath10k wcn3990 values (33 peers, skid 16, bcn offload 2, host_capab MGMT_BUNDLE_TX_COMPL),
  vdev NSS 2 after vdev create, WMI queue 8 → 32 (the extra commands had dropped vdev create).
- All accepted by fw (scan still works: 13–14 networks), but vdev start still asserts:
  `EX:wlan_process:0x1:WLAN RT:0x1084:PC=0xb01ab7b0`, modem ERR-FATAL. Tests 4 and 6.
- Bisect is effectively done: every command up to and including vdev wmm is fine; vdev start is the trigger.
- Side issues: in-place `wland` restart reset the phone once (test 5); test-6 boot lost USB/SSH for 10 min,
  watchdog returned it to fastboot. Joins now via reboot; recovery boot uses `sweetwifi=0`.
- wlan.conf deleted after every test, verified absent (last check 13:50 on k46).
- Next: Phase 3 — firmware debug log (WMI_DBGLOG_CFG + diag pipe) to see what vdev start does before the assert.

## [17:36] STOP — hard hang (demo boot k50, flamereboot=0)
- k50 (demo: sweettouch=2, sweetwifi=0, flamereboot=0) booted 17:10, USB link came up again at 17:15, the live
  log stops at 82 s uptime, phone answers neither ARP nor SSH, no fastboot. flamereboot=0 means no timed return.
- Needs a human: hold power (+vol down) to reach fastboot.
- Test 8 (scan only 2437 MHz) never ran: the phone was already unreachable when it started. The tests 6 and 8
  "hangs" earlier may be the same thing: phone alive per its own log but no USB networking.
- Wi-Fi Phase 3 so far: dbglog over WMI gives nothing (WCN3990 logs via diag). Firmware disassembled
  (llvm-mc hexagon). Crash function 0xb01ab640 = WMI event buffer-pool allocator; pool struct (0x934 bytes,
  malloc'd at init, global gp+0x6b0) has its header array pointers (+0x10/+0x14/+0x18) overwritten →
  firmware heap overflow from a neighbouring block, somewhere between init and vdev start.
- wlan.conf: not present at last check (k49, 17:0x); test 8 rerun never wrote it (phone unreachable).

## [18:56] STOP — iOS USB (USB 2) dead on every boot since ~17:15; fastboot (USB 3) fine
- PC: `usb 5-2-port2: Cannot enable. Maybe the USB cable is bad?` on every iOS boot (k51–k56).
- Not software: fails with Wi-Fi off, after `fastboot reboot-bootloader`, and with this morning's kernel14
  (GPU off) that ran all day. Port power-cycle and dock USB2 hub reset changed nothing.
- Needs a human: unplug/replug the cable (or another port/cable), full power-off of the phone.
- Found on the way, fixed: GPU pool range 2 began at 0xe1000000 = wland's rmtfs buffer (hyp-assigned to
  the modem). xnu 0150 starts it at 0xe1400000 (kernel26).
- No wlan.conf written since k49 (verified absent then).

## [20:00] Offline work while the phone is unreachable
- wland (CI 40041467448): ath10k station steps we skipped, behind /var/local/wlan-steps.conf (hex, default 0xf):
  bit0 STA_KEEPALIVE off (0x1c005, tags 0x7f/0x80), bit1 sta ps params (0x9002 tag 0x6d: rx wake WAKE,
  tx wake ALWAYS, pspoll NO_MAX), bit2 vdev RTS threshold 0xffffffff, bit3 vdev start in HT20 mode (5/4, was 11G/11A).
- tools/sunfish-wifitest.sh: guarded join test (WIFI_PSK via env only, lock, aborts if unreachable,
  always deletes + verifies wlan.conf, recovery boot with sweetwifi=0, log to logs/wland-NAME.log).
- Checked vs mainline (no difference): board file (byte-identical google_sunfish BDF), sunfish DT (no quirks),
  QMI cfg/host_cap/BDF/cal report, CE tables, TFTP serving, firmware-5.bin features.
- USB: sunfish HS PHY is QUSB2 v2 (mainline sm7150.dtsi), the driver ran flame's femto init on it.
  xnu 0151 (kernel27): GCC_QUSB2PHY_PRIM_BCR pulse + Linux qusb2 v2 table (sweetqusb=0 = old path).
  k57 (kernel27, 19:52): USB 2 still does not enumerate → needs the physical replug / cold power-off.

## [20:55] Wi-Fi join — **ROOT CAUSE FOUND, JOIN WORKS**
- Cause: we gave the WLAN firmware a 1 MB MSA region over QMI; sunfish's DT wlan_msa_mem is
  0x98d00000 + **2 MB**. The firmware heap's upper half was never assigned to it → its WMI event buffer pool
  (allocator 0xb01ab640) got corrupted → assert at the first heavy allocation (vdev start).
- Found by bisecting with wlan-steps probes: crash with no scan (k64), no HTT setup (k65), and no
  regdomain/pdev/chan list (k66) → only QMI/INIT/vdev left → compared MSA vs mainline sunfish DTS.
- Fix: wlfw.c MSA_SIZE 0x200000 (CI 40046754986). k67 probe: `vdev start resp: status 0`.
- k68 join test: auth 0, assoc 0 aid 1, 4-way handshake done, `*** joined 'Johann' ***`, rx frames to IP.
- Open: wland's own wlan.conf join (bridge mode) gets no IP on en0 — iOS (configd) only does DHCP for
  networks wifid joined. Next: join from Settings → Wi-Fi.
- wlan.conf deleted + verified after every test.

## [21:10] Wi-Fi — **ON THE INTERNET**
- Join from Settings → Wi-Fi works (wifid → /dev/wlan → wland): associated, state 4, link up.
- No IP at first: iOS's preferences.plist had no network set (written before en0 existed), so configd never
  made a Wi-Fi service and IPConfiguration never ran DHCP. tools/sunfish-netprefs.py adds the Wi-Fi (en0,
  DHCP) service + set and restarts configd (backup: logs/preferences.plist.bak-*).
- Result: en0 192.168.2.30/24, router + DNS 192.168.2.1, primary interface en0;
  nettest: DNS apple.com OK, TCP OK, HTTPS 200.
