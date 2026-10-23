
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
