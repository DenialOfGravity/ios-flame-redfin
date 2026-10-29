#!/bin/bash
# devices/redfin/pull-firmware.sh: pull the Pixel 5's own vendor firmware that the port loads, over adb, into
# fw-redfin/ at the top of the repository (git-ignored: the files are Google's and Qualcomm's, never committed).
# The vayu port's pull-firmware.sh convention. Idempotent: a file already in fw-redfin/ with the phone's size is
# not pulled again; run it again after a ROM update to refresh. Missing files are told, not fatal.
#
# The phone: stock Android with adb (the /vendor and /vendor/firmware_mnt partitions are world-readable there),
# or TWRP (`adb root`): then /vendor and the modem partition are mounted read-only here first, as
# tools/redfin-recon.ps1 does. Read-only on the phone. The names come from what the code loads:
#   fw-redfin/            -> the phone's /private/var/local/fw/       (tools/redfin-install-*-wsl.sh put them there)
#     a650_sqe.fw a650_gmu.bin a620_zap.mdt/.bNN  GPU (xnu 0904; mkpayload --gpufw puts them in the ADT)
#     adsp.mdt adsp.bNN                            audio DSP (xnu 0915 image_file "adsp.mdt", "adsp.b%02u")
#     adspr.jsn adsps.jsn adspua.jsn               its PD tables (xnu 0951 serves their content from a table)
#     crbtfw32.tlv crnv32.bin crnv32u.bin          Bluetooth rampatch + NVM (phone/bt/btd.c: crbtfw%02x.tlv,
#                                                  crnv%02x[u].bin for the ROM btd reads; redfin: 32)
#   fw-redfin/modem/      -> /var/local/fw/modem/  (phone/wifi: wland.c FW_DIR, tftp.c, wlfw.c BDF_PATH[2])
#     modem.mdt modem.bNN modemr.jsn               modem DSP (runs the WLAN firmware), from the modem partition
#     wlanmdsp.mbn modemuw.jsn                     WLAN user PD, fetched by the modem over TFTP
#     bdwlan-redfin.bin bdwlan-u-redfin.bin        WLAN board data
# Not pulled here: the modemst1/modemst2/fsg/fsc partitions rmtfs serves (they hold the IMEI: a partition backup,
# not firmware), the ADSP sensors PD's files (/vendor/etc/sensors, acdbdata, persist/sensors: the persist
# partition holds calibration, see tools/redfin-install-hexagon-wsl.sh) and the camera module files (vendor
# /vendor/lib64/camera/com.qti.sensormodule.*_lito2.bin, turned into fw/camera-*.tab by tools/redfin-camtab.py).
set -e -o pipefail
cd "$(dirname "$0")/../.."
OUT=fw-redfin
mkdir -p "$OUT/modem"
adb get-state >/dev/null
ash() { adb shell "$@" 2>/dev/null | tr -d '\r'; }
miss=0 got=0 kept=0

# TWRP: /vendor/firmware(_mnt) are not mounted; mount vendor and modem read-only where they are expected
if [ -z "$(ash 'ls /vendor/firmware 2>/dev/null | head -1')" ]; then
	slot=$(ash 'getprop ro.boot.slot_suffix')
	ash "mkdir -p /tmp/rv /tmp/rm; mount -o ro /dev/block/mapper/vendor$slot /tmp/rv; mount -t vfat -o ro /dev/block/by-name/modem$slot /tmp/rm" >/dev/null || true
	VF=/tmp/rv/firmware MI=/tmp/rm/image
	trap 'adb shell "umount /tmp/rm; umount /tmp/rv" >/dev/null 2>&1 || true' EXIT
else
	VF=/vendor/firmware MI=/vendor/firmware_mnt/image
fi

pull_one() { # PHONE_PATH DEST_DIR
	local name=${1##*/} size have
	size=$(ash "stat -c %s '$1' 2>/dev/null")
	if [ -z "$size" ]; then echo "pull-firmware.sh: $1: not on the phone"; miss=$((miss + 1)); return; fi
	have=$(stat -c %s "$2/$name" 2>/dev/null || stat -f %z "$2/$name" 2>/dev/null || echo -)
	if [ "$have" = "$size" ]; then kept=$((kept + 1)); return; fi
	if adb pull "$1" "$2/$name.part" >/dev/null 2>&1; then mv -f "$2/$name.part" "$2/$name"; got=$((got + 1))
	else rm -f "$2/$name.part"; echo "pull-firmware.sh: $1: pull failed"; miss=$((miss + 1)); fi
}
find_pull() { # DEST_DIR NAME_GLOB...: wherever the phone keeps it (firmware dirs first, then all of /vendor)
	local dest=$1 g p; shift
	for g in "$@"; do
		# in this order (ls sorts its operands, so one ls each): the vendor copy of wlanmdsp.mbn/modemuw.jsn,
		# not the modem image's, is the one the port uses (tools/redfin-install-wifi-wsl.sh "vendor")
		p=$(ash "ls -d $VF/$g 2>/dev/null; ls -d $MI/$g 2>/dev/null; find /vendor -name '$g' 2>/dev/null" | awk '!seen[$0]++')
		if [ -z "$p" ]; then echo "pull-firmware.sh: $g: not found under $VF, $MI or /vendor"; miss=$((miss + 1)); continue; fi
		# one copy per file name (the first place it was found)
		while read -r f; do [ -n "$f" ] && pull_one "$f" "$dest"; done < <(echo "$p" | awk -F/ '!seen[$NF]++')
	done
}

# GPU (xnu 0904: kgsl a620 = sqe a650_sqe.fw, gmu a650_gmu.bin, zap a620_zap)
find_pull "$OUT" a650_sqe.fw a650_gmu.bin 'a620_zap.mdt' 'a620_zap.b[0-9][0-9]'
# audio DSP and its PD tables (xnu 0915, 0951)
find_pull "$OUT" adsp.mdt 'adsp.b[0-9][0-9]' adspr.jsn adsps.jsn adspua.jsn
# Bluetooth (phone/bt/btd.c; the WCN3998 on redfin reads ROM 0x32)
find_pull "$OUT" 'crbtfw*.tlv' 'crnv*.bin'
# modem DSP + WLAN (phone/wifi; tools/redfin-install-wifi-wsl.sh)
find_pull "$OUT/modem" modem.mdt 'modem.b[0-9][0-9]' modemr.jsn wlanmdsp.mbn modemuw.jsn 'bdwlan*redfin.bin'

echo "pull-firmware.sh: $OUT: $got pulled, $kept already there, $miss missing; $(find "$OUT" -type f | wc -l | tr -d ' ') files"
[ "$miss" -eq 0 ] || echo "pull-firmware.sh: missing files are listed above (names from the code: see the header)"
