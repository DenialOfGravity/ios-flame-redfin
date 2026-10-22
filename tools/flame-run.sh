#!/bin/bash
# One experiment on the phone, end to end:
#
#   tools/flame-run.sh NAME [-k KERNEL] [-s SECS] [-a "EXTRA BOOT-ARGS"] [-f FILM_SECS] [-g REGEX]
#                           [-p POKE_SCRIPT]   (bsd/dev/sweet_poke.c; output lines start "POKE:")
#                           [-G]  Adreno firmware in the ADT + sweetgpu=1 (bsd/dev/sweet_gpu.c)
#
#   1. payload + boot image from KERNEL (default: the last build) with the base
#      boot-args, flamereboot=SECS (default 300) and the extra args
#   2. phone to fastboot (from TWRP or fastboot), boot it, optionally film it
#   3. wait for the run to end (the shim's PMIC reason brings it back to fastboot)
#   4. rescue boot (probe shim: saves the previous kernel's RAM log tail), then TWRP
#   5. pull + decode the XNU ring, the shim log and the rescue into logs/runs/NAME/
#      and print a summary (panics, errors, last lines, lines matching REGEX)
#
# The phone is left in TWRP.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
name=$1; shift
kernel=$ROOT/work/dxb/build/xnu.obj/DEVELOPMENT_ARM64_SWEET/kernel.development.sweet
secs=300 extra="" film=0 grep_re="" poke="" gpu=0
while getopts "k:s:a:f:g:p:G" o; do
	case $o in
	k) kernel=$OPTARG ;; s) secs=$OPTARG ;; a) extra=$OPTARG ;; f) film=$OPTARG ;; g) grep_re=$OPTARG ;;
	p) poke=$OPTARG ;;
	G) gpu=1 ;;
	*) exit 2 ;;
	esac
done
base="debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsrw=1 rootrw=1"
base="$base unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin launchd_unsecure_cache=1"
base="$base wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60 ufslogsecs=2"
cmdline="$base flamereboot=$secs $extra"
# Real time: PM8150 RTC + offset (tools/flame-rtc.py calibrates it once).
[ -f "$ROOT/work/rtc-offset" ] && cmdline="$cmdline sweetrtcoff=$(cat "$ROOT/work/rtc-offset")"
out=$ROOT/logs/runs/$name
mkdir -p "$out" "$ROOT/work/boot/runs"
img=$ROOT/work/boot/runs/$name.img
cp "$kernel" "$out/kernel"
echo "$cmdline" > "$out/cmdline"
pokearg=()
if [ -n "$poke" ]; then cp "$poke" "$out/poke.txt"; pokearg=(--poke "$poke"); fi
if [ "$gpu" = 1 ]; then pokearg+=(--gpufw research/gpu/fw); cmdline="$cmdline sweetgpu=1"; echo "$cmdline" > "$out/cmdline"; fi
python3 tools/mkpayload.py "$kernel" work/boot/flame-hi.adt "$out/payload.bin" --cmdline "$cmdline" ${pokearg[@]+"${pokearg[@]}"} >/dev/null
shim/build.sh "$out/payload.bin" "$img" >/dev/null 2>&1
rm -f "$out/payload.bin"
# The probe shim (no payload) for the rescue boot: build it once per shim change.
probe=$ROOT/work/boot/shim-probe.img
if [ ! -f "$probe" ] || [ -n "$(find shim -newer "$probe" -name '*.[chS]' | head -1)" ]; then
	shim/build.sh "" "$probe" >/dev/null 2>&1
fi

to_fastboot() {
	if ! fastboot devices | /usr/bin/grep -q .; then
		adb reboot bootloader 2>/dev/null || true
		for i in $(seq 1 90); do fastboot devices | /usr/bin/grep -q . && break; sleep 1; done
	fi
	fastboot devices | /usr/bin/grep -q . || { echo "phone not in fastboot" >&2; exit 1; }
}
wait_fastboot() {	# $1: timeout in s
	for i in $(seq 1 "$1"); do fastboot devices | /usr/bin/grep -q . && return 0; sleep 1; done
	return 1
}

to_fastboot
t0=$(date +%s)
echo "$(date +%T) boot $name ($secs s): $cmdline"
fastboot boot "$img" 2>&1 | tail -1
if [ "$film" != 0 ]; then
	tools/watch-boot.sh "$out/film" "$film" >/dev/null 2>&1 &
fi
sleep 10
livepid=""
case " $cmdline " in *" sweetusb=2 "*)
	# Live console over USB Ethernet into the run directory; end the run early
	# with tools/flame-cmd.py reboot (stop flame-live first: one UDP listener).
	python3 tools/flame-live.py "$out/live.txt" --grep '^$' >/dev/null 2>&1 &
	livepid=$!
	echo "live log -> $out/live.txt (end early: tools/flame-cmd.py reboot)" ;;
esac
if ! wait_fastboot $((secs + 180)); then
	echo "run did not return to fastboot in $((secs + 180)) s; leaving it" >&2
	exit 1
fi
[ -n "$livepid" ] && kill "$livepid" 2>/dev/null || true
echo "$(date +%T) back in fastboot after $(( $(date +%s) - t0 )) s; rescue boot"
fastboot boot "$probe" 2>&1 | tail -1
sleep 8
wait_fastboot 90 || { echo "rescue boot did not return" >&2; exit 1; }
tools/flame-twrp.sh >/dev/null
tools/flame-log-pull.sh xnu "$out/xnu.bin" >/dev/null
python3 tools/flame-log-decode.py "$out/xnu.bin" "$out/xnu.txt" >/dev/null || true
rm -f "$out/xnu.bin"
tools/flame-log-pull.sh shim "$out/shim.txt" >/dev/null
tools/flame-log-pull.sh rescue "$out/rescue.txt" || true
wait 2>/dev/null || true

echo "=== $name: $(wc -l < "$out/xnu.txt") xnu lines, rescue $(wc -c < "$out/rescue.txt") bytes"
/usr/bin/grep -a -i -m 20 "panic\|CRASH \|stuck\|timeout\|failed" "$out/xnu.txt" | cut -c1-200 || true
echo "--- last lines (xnu ring)"; tail -5 "$out/xnu.txt" | cut -c1-200
echo "--- last lines (RAM rescue)"; tail -5 "$out/rescue.txt" | cut -c1-200
if [ -n "$poke" ]; then
	echo "--- POKE"; /usr/bin/grep -a -h "POKE:" "$out/xnu.txt" "$out/rescue.txt" | sort -u | cut -c1-200 | head -80
fi
if [ -n "$grep_re" ]; then
	echo "--- /$grep_re/"; /usr/bin/grep -a -E "$grep_re" "$out/xnu.txt" "$out/rescue.txt" | cut -c1-220 | tail -40
fi
