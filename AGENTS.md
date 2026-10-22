# Working on ios-flame

- Read `README.md`, then `NOTES.md` (hardware facts, ABL boot image rules, test loop) and the top of
  `HANDOFF.md` ("Start here": the newest state, newest first). ios-sweet's history is in `docs/ios-sweet/`.
- Record each milestone in `HANDOFF.md` under "Start here", with the kernel number, the boot args, exact
  results and what is still open. Keep observations apart from guesses. A new kernel patch is one line in
  `NOTES.md` ("Flame patches") too.
- Kernel changes: edit `work/dxb/xnu` (a git repo, HEAD = baseline + applied patches), commit, and save the diff
  as the next `xnu/patches/NNNN-flame-*.patch`. `tools/build-xnu.sh` builds locally in minutes.
- Device bring-up uses temporary `fastboot boot` images. Never flash ABL, XBL, TZ, modem or other firmware
  partitions, never relock the bootloader on modified software, and keep the partition backups intact.
  Confirm each destructive step with the user before running it. `RECOVERY.md` restores stock Android.
- Keep out of git: partition dumps, device trees and logs from a phone (serials, IMEI, network names),
  Apple's files (IPSW parts, the root image, shared cache, kernelcache, anything translated from Apple's
  shaders), Google and Qualcomm images and firmware, and Wi-Fi credentials (`/var/local/wlan.conf` lives on
  the phone only).
