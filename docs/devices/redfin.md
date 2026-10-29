# Google Pixel 5 (redfin): status

Made by `tools/docs-gen.py redfin` from [devices/redfin/device.conf](../../devices/redfin/device.conf); edit that file, not this page.

| | |
|---|---|
| title | Google Pixel 5 |
| vendor | Google |
| soc | sm7250 (lito, Snapdragon 765G) |
| ios | iOS 16.7.16 (iPhone X userland) |
| known-good | r57a (kernel ws-y-int-safe @ b1e8c0b) |
| boot | boot.conf (RAM only: fastboot boot, never flashed) |
| firmware | pull-firmware.sh (output fw-redfin/, git-ignored) |
| soc-args | pull-soc.sh + tools/soc-args.py --check (SoC addresses the code hard-codes vs the phone's DT) |
| plan | docs/redfin/port-plan.md, docs/redfin/qol-plan.md |

## Subsystems

15 works, 2 partial, 4 missing (of 21).

| Subsystem | State | Notes |
|---|---|---|
| boot | works | RAM-only fastboot boot of the shim + XNU payload into iOS on userdata (0900); power and volume keys (vol+ PM8150L GPIO5) |
| display | works | S6E3HC2 cmd-mode DSC panel, 1080x2340 at 90 Hz, direct scanout (0943-0998) |
| touch | works | Samsung sec_ts touch controller (0901) |
| gpu | works | Adreno 620 + Metal (SweetMetal2 bundle on the phone; 0904, 0908, 1000) |
| cpu | works | cpufreq with readback and a DVFS governor (0961-0963, 0970) |
| thermal | works | TSENS temperature readout, tsens0/tsens1 (0960; caps 0964) |
| storage | works | HFS+ root on userdata (journaled, 109 GiB), Files > On My iPhone and iPhone Storage (1030) |
| backlight | works | panel brightness in nits for CoreBrightness (0906, 0973) |
| torch | works | camera flash LED as the torch (0918, 0933) |
| haptics | works | TI DRV2624 on QUP I2C SE3 (0907, 0909, 0912) |
| audio | works | speaker (two CS35L41 amps) and microphone through the ADSP (0915-0917, 0952-0958) |
| camera | works | Camera.app capture (0919-0934); needs fw/camera-<sensor>.tab made by tools/redfin-camtab.py from the vendor module file |
| usb | works | USB networking (CDC Ethernet) and the live kernel log |
| wifi | works | WCN3990 via the modem DSP, wland in userland, wifid joins (1012 + 1013); 1014 signal events excluded: they reset the phone on wifid's join |
| bluetooth | works | WCN3998 HCI over UART (btd, 0981/0982, 1010, 1015): scan and basic connect; a crash when pairing headphones is under investigation |
| battery | partial | charge level is an estimate (SDAM-seeded coulomb count + voltage, 0966); not calibrated |
| sensors | partial | accelerometer and gyroscope as HID services work (ADSP sensors PD over fastrpcd/sensd, 0971/0972); proximity crashes backboardd |
| charging | missing | does not charge under iOS (SMB5 policy 0967/0968 in tree); charges only in fastboot |
| cellular | missing | the modem DSP is booted (by wland) only to run Wi-Fi; no SIM, voice or data |
| nfc | missing | not started |
| gps | missing | not started |
