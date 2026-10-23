#!/bin/bash
# Write the iOS root image to the Pixel 5's userdata partition, from WSL, through TWRP.
# THIS ERASES ANDROID'S USER DATA (apps, photos, settings). Android itself (system, vendor, boot)
# is not touched; a factory reset (or the factory image) brings Android back.
#
#   bash tools/redfin-install-root-wsl.sh            checks, asks you to type ERASE, writes, verifies
#   bash tools/redfin-install-root-wsl.sh verify     only compare the phone's copy with the image
#   bash tools/redfin-install-root-wsl.sh delta      rewrite only the GiBs that differ from the image
#                                                    (phone must already hold the iOS root: HFS+)
#
# Needs: the phone in TWRP (fastboot boot twrp-*-redfin.img), Windows adb.exe on PATH in WSL (WSL
# shares the Windows PATH) or ADB=/mnt/c/.../adb.exe, ~/redfin-work/iosroot.img from
# redfin-mkroot-wsl.sh. HANDOFF.md: write from TWRP with dd, never `fastboot flash userdata` (ABL hung
# on the last chunk on flame).
set -euo pipefail
cd "$(dirname "$0")/.."
W=${REDFIN_WORK:-$HOME/redfin-work}
IMG=$W/iosroot.img SUMS=work/iosroot/iosroot.gib.sha256
PART=/dev/block/sda19                    # recon 2026-10-23: userdata = sda19, start 0x27d000 (4K)
ADB=${ADB:-$(command -v adb.exe || command -v adb || true)}
[[ -n $ADB ]] || { echo "adb.exe not found: export ADB=/mnt/c/path/to/platform-tools/adb.exe"; exit 1; }
# adb shell must not read the loops' stdin (it would swallow the checksum list)
sh_() { "$ADB" shell "$@" </dev/null | tr -d '\r'; }

[[ -f $IMG && -f $SUMS ]] || { echo "need $IMG and $SUMS (run redfin-mkroot-wsl.sh build)"; exit 1; }
size=$(stat -c %s "$IMG")
echo "== phone"
"$ADB" devices | tr -d '\r' | sed 1d | grep . || { echo "no device"; exit 1; }
state=$("$ADB" get-state 2>/dev/null | tr -d '\r' || true)
[[ $state == recovery ]] || { echo "phone is '$state', not in TWRP (recovery): boot TWRP first"; exit 1; }
[[ $(sh_ id) == *uid=0* ]] || { echo "adb is not root"; exit 1; }
model=$(sh_ getprop ro.product.device)
[[ $model == redfin ]] || { echo "device is '$model', not redfin: stopping"; exit 1; }
target=$(sh_ readlink -f /dev/block/by-name/userdata)
[[ $target == "$PART" ]] || { echo "userdata is $target, expected $PART: stopping"; exit 1; }
psize=$(sh_ blockdev --getsize64 "$PART")
(( psize >= size )) || { echo "partition ($psize) smaller than image ($size)"; exit 1; }
printf '  device %s, userdata %s, %s bytes; image %s bytes\n' "$model" "$PART" "$psize" "$size"

verify() {
	echo "== verify: SHA-256 of each GiB on the phone vs the image"
	local bad=0 i want got
	while read -r i want <&3; do
		got=$(sh_ "dd if=$PART bs=4194304 skip=$((i * 256)) count=256 2>/dev/null | sha256sum" | cut -d' ' -f1)
		if [[ $got == "$want" ]]; then echo "  GiB $i ok"; else echo "  GiB $i MISMATCH ($got)"; bad=1; fi
	done 3< "$SUMS"
	[[ $bad == 0 ]] && echo "verify: all $(wc -l < "$SUMS") GiB match" || { echo "verify: FAILED"; exit 1; }
}
if [[ ${1:-} == verify ]]; then verify; exit 0; fi

if [[ ${1:-} == delta ]]; then
	# Only when userdata already holds our HFS+ root (signature "H+" / "HX" at byte 1024), so this
	# can never be the step that overwrites Android data.
	sig=$(sh_ "dd if=$PART bs=1024 skip=1 count=1 2>/dev/null | od -An -c -N2" | tr -d ' ')
	[[ $sig == "H+" || $sig == "HX" ]] || { echo "userdata does not hold an HFS+ volume ($sig): use the full install"; exit 1; }
	echo "== delta: compare each GiB, rewrite the ones that differ"
	n=0
	while read -r i want <&3; do
		got=$(sh_ "dd if=$PART bs=4194304 skip=$((i * 256)) count=256 2>/dev/null | sha256sum" | cut -d' ' -f1)
		[[ $got == "$want" ]] && { echo "  GiB $i same"; continue; }
		echo "  GiB $i differs: writing"
		dd if="$IMG" bs=4194304 skip=$((i * 256)) count=256 status=none |
			"$ADB" exec-in "dd of=$PART bs=4194304 seek=$((i * 256)) conv=notrunc"
		n=$((n + 1))
	done 3< "$SUMS"
	sh_ sync
	echo "  rewrote $n GiB"
	verify
	echo "delta: done. Reboot to fastboot with: $ADB reboot bootloader"
	exit 0
fi

echo
echo "This overwrites the first $((size >> 30)) GiB of $PART (Android's userdata: apps, photos, settings)."
echo "Android's system, boot and vendor partitions are not touched. Backup of the other partitions: backup\\."
read -r -p "Type ERASE to continue: " ok
[[ $ok == ERASE ]] || { echo "not confirmed; nothing written"; exit 1; }

echo "== unmount /data in TWRP (if mounted)"
sh_ 'umount /data 2>/dev/null; umount /sdcard 2>/dev/null; grep -c " /data " /proc/mounts || true'
echo "== writing $((size >> 20)) MiB (adb, about 5-15 min)"
if command -v pv >/dev/null; then pv "$IMG"; else cat "$IMG"; fi |
	"$ADB" exec-in "dd of=$PART bs=4194304"
sh_ sync
verify
echo "install: done. Reboot to fastboot with: $ADB reboot bootloader"
