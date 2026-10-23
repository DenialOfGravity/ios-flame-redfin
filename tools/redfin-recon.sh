#!/bin/bash
# Collect the Pixel 5 (redfin) facts the port needs but the kernel source can't give:
# the live device tree ABL hands over, the real RAM map, partition layout, firmware
# file names and the boot image headers. Read-only on the phone: nothing is written,
# flashed or erased.
#
#   tools/redfin-recon.sh android      phone booted in stock Android, USB debugging on
#   tools/redfin-recon.sh twrp         phone in TWRP (adb root): live DT, iomem, partitions
#   tools/redfin-recon.sh images DIR   unpacked factory image dir (boot.img, vendor_boot.img,
#                                      vendor.img): boot headers + firmware listing
#
# Output goes to recon/ (gitignored: the live DT and getprop hold the serial number).
# Works from Linux, macOS, or Git Bash / WSL on Windows with platform-tools on PATH.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=recon; mkdir -p "$OUT"
mode=${1:-}
sh_() { adb shell "$@" 2>&1 | tr -d '\r'; }

case "$mode" in
android)
	adb wait-for-device
	sh_ getprop > "$OUT/getprop.txt"
	for k in ro.product.device ro.build.fingerprint ro.bootloader ro.boot.flash.locked \
		 ro.boot.verifiedbootstate sys.oem_unlock_allowed ro.boot.slot_suffix ro.boot.hardware.revision; do
		printf '%-32s %s\n' "$k" "$(sh_ getprop $k)"
	done | tee "$OUT/summary-android.txt"
	sh_ cat /proc/cmdline > "$OUT/cmdline-android.txt"
	sh_ ls -l /dev/block/by-name/ > "$OUT/by-name-android.txt" 2>&1
	echo "Next: back up the per-device partitions (see docs/redfin/port-plan.md, step 0) before anything else."
	;;
twrp)
	adb wait-for-recovery 2>/dev/null || adb wait-for-device
	sh_ id | grep -q 'uid=0' || { echo "need adb root (TWRP)"; exit 1; }
	adb pull /sys/firmware/fdt "$OUT/live.dtb" >/dev/null
	command -v dtc >/dev/null && dtc -q -I dtb -O dts "$OUT/live.dtb" -o "$OUT/live.dts"
	sh_ cat /proc/iomem > "$OUT/iomem.txt"
	sh_ cat /proc/cmdline > "$OUT/cmdline-twrp.txt"
	sh_ ls -l /dev/block/by-name/ > "$OUT/by-name.txt"
	# userdata: which sdX, first LBA and size (the shim finds it via GPT, but the
	# log-pull scripts and the root-image dd need the block device)
	sh_ 'for d in /sys/block/sd*/sd*; do n=${d##*/}; echo "$n start=$(cat $d/start) size=$(cat $d/size) $(grep PARTNAME $d/uevent)"; done' > "$OUT/partitions.txt"
	sh_ 'for d in /sys/block/sd?; do echo "${d##*/} lbs=$(cat $d/queue/logical_block_size)"; done' >> "$OUT/partitions.txt"
	sh_ dmesg > "$OUT/dmesg-twrp.txt"
	# memory + reserved-memory as ABL patched them
	sh_ 'for f in /proc/device-tree/memory*/reg; do echo $f; od -An -tx4 -v $f; done' > "$OUT/memory-reg.txt"
	sh_ 'ls /proc/device-tree/reserved-memory/' > "$OUT/reserved-memory.txt"
	sh_ 'cat /proc/device-tree/model; echo; od -An -tx4 /proc/device-tree/qcom,board-id; od -An -tx4 /proc/device-tree/qcom,msm-id' > "$OUT/model.txt"
	grep -E 'userdata' "$OUT/partitions.txt"
	cat "$OUT/memory-reg.txt"
	echo "Saved to $OUT/. Send live.dts (or live.dtb), iomem.txt, partitions.txt and model.txt."
	;;
images)
	D=${2:?factory image dir}
	{
		for img in boot.img vendor_boot.img; do
			[ -f "$D/$img" ] || continue
			echo "== $img"
			if command -v unpack_bootimg >/dev/null; then unpack_bootimg --boot_img "$D/$img" --out "$OUT/unpack-${img%.img}" 2>&1 | head -40
			else python3 -I downloads/mkbootimg/unpack_bootimg.py --boot_img "$D/$img" --out "$OUT/unpack-${img%.img}" 2>&1 | head -40; fi
		done
	} | tee "$OUT/bootimg-headers.txt"
	# firmware names (GPU, Wi-Fi BDF, modem) from a mounted or extracted vendor image
	if [ -d "$D/vendor/firmware" ]; then
		ls -l "$D/vendor/firmware" > "$OUT/vendor-firmware.txt"
		grep -E 'a6[0-9]0|a620|zap|gmu|sqe|bdwlan|wlanmdsp|modem' "$OUT/vendor-firmware.txt"
	else
		echo "Extract vendor.img (simg2img + 7z/debugfs) to $D/vendor to list /vendor/firmware."
	fi
	;;
*)
	sed -n 2,14p "$0"; exit 1 ;;
esac
