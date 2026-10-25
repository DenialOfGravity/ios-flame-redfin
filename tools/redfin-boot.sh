#!/bin/bash
# Pack kernel + ADT + boot-args into a shim boot image and fastboot-boot it
# on the Pixel 5 (redfin). RAM only: nothing is flashed.
#
#   tools/redfin-boot.sh NAME KERNEL [EXTRA BOOT-ARGS...]
#
# Waits for the phone to show up in fastboot (e.g. after flamereboot).
# Image: work/boot/NAME.img; args: work/boot/NAME.cmdline.
#
# Environment (C5: the present/clock experiments are one variable each):
#   PRESET=camera  the r18g+ line (GPU=2, Metal v2, sec_ts touch, haptics, backlight, torch, cameras, sweetnull)
#   GPU=0|1|2      CPU rendering / kernel GPU present / plus Metal on Turnip (PRESET=camera sets 2)
#   FLIP=1         double-buffered present (0905 sweetfbflip=1)          e.g. r19b: PRESET=camera FLIP=1
#   GPUFREQ=1..4   sweetgpufreq: 275 / 400 / 500 (default 3) / 625 MHz    e.g. r19c: PRESET=camera GPUFREQ=4
#   NOBOOT=1       build work/boot/NAME.img only (no fastboot)
# Read the result from the klog: "present: 300 frames in N ms = F/s (single buffer|flip, gpufreq G); ... put off,
# flips, late" (0942) and "5s: ... GPU busy" lines.
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1 kernel=$2; shift 2
P=$PWD/work/boot
base="debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsrw=1 rootrw=1"
base="$base unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin launchd_unsecure_cache=1"
base="$base wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60 ufslogsecs=2 flamereboot=1800"
base="$base flametouch=0 sweettouch=0 sweetkeys=1 sweetusb=2 sweetgpu=0 sweetgpufreq=3 sweetgpudelay=0 sweetfb_thread=0 sweetmtl=0 sweetddr=0"
base="$base sweetbattery=1 sectouch=0"
# redfin: touch is Samsung sec_ts on SPI SE0 (sectouch=1), so sweettouch/flametouch stay 0.
# GPU (A620, xnu 0904/0905): sweetgpu=0 sweetmtl=0 = CPU rendering. GPU=1 below = kernel GPU + the GPU
# present (CA still renders on the CPU); GPU=2 = plus Metal on Turnip (sweetmtl=2, needs the metal2 install);
# FLIP=1 adds the double-buffered present (sweetfbflip=1). sweetgpufreq: 1 275, 2 400, 3 500, 4 625 MHz.
if [ "${PRESET:-}" = camera ]; then
	GPU=${GPU:-2}
	base=$(printf '%s\n' $base | grep -v -e '^sectouch=' | tr '\n' ' ')
	base="$base sectouch=1 sectouchdelay=20 sweethaptic=2 sweetbl=1 sweetnull=backboardd,SpringBoard,mediaserverd"
	base="$base sweettorch=2 sweetcam=2 sweetcamdev=1"
elif [ -n "${PRESET:-}" ]; then
	echo "unknown PRESET=$PRESET (camera)" >&2
	exit 1
fi
GPU=${GPU:-0}
if [ "$GPU" -ge 1 ]; then
	base=$(printf '%s\n' $base | grep -v -e '^sweetgpu=' -e '^sweetfb_thread=' -e '^sweetddr=' | tr '\n' ' ')
	base="$base sweetgpu=1 sweetfb_thread=1 sweetddr=1"
	[ "${FLIP:-0}" = 1 ] && base="$base sweetfbflip=1"
fi
if [ "$GPU" -ge 2 ]; then
	base=$(printf '%s\n' $base | grep -v -e '^sweetmtl=' | tr '\n' ' ')
	base="$base sweetmtl=2"
fi
if [ -n "${GPUFREQ:-}" ]; then
	base=$(printf '%s\n' $base | grep -v -e '^sweetgpufreq=' | tr '\n' ' ')
	base="$base sweetgpufreq=$GPUFREQ"
fi
# Real time: PM8150 RTC + offset (tools/flame-rtc.py LOG calibrates it once).
[ -f work/rtc-offset ] && base="$base sweetrtcoff=$(cat work/rtc-offset)"
# Extra args replace defaults with the same key (XNU would take the first).
for a in "$@"; do
	k=${a%%=*}
	base=$(printf '%s\n' $base | grep -v -x -e "$k" -e "$k=.*" | tr '\n' ' ')
done
cmdline="$base $*"
echo "$cmdline" > "$P/$name.cmdline"
python3 -I tools/mkpayload.py "$kernel" "$P/redfin-hi.adt" "$P/$name.payload" --cmdline "$cmdline" --gpufw "${GPUFW:-/mnt/c/ClaudeProjects/iOS_Pixel5/ios-redfin-tree/ios-redfin/recon/fw}" >/dev/null
shim/build.sh "$P/$name.payload" "$P/$name.img" >/dev/null
if [ "${NOBOOT:-0}" = 1 ]; then
	echo "$(date +%T) built $P/$name.img: $cmdline"
	exit 0
fi
echo "$(date +%T) built $name.img; waiting for fastboot"
until fastboot devices | grep -q fastboot; do sleep 2; done
fastboot boot "$P/$name.img"
echo "$(date +%T) booted $name: $cmdline"
