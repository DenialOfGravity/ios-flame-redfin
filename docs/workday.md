
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
