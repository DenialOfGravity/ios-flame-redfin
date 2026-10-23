#!/bin/bash
# Read files from the phone's iOS root without USB/SSH: copy only the GiBs that changed on the phone
# into a sparse copy of ~/redfin-work/iosroot.img, mount it read-only, and save the logs (wland,
# kernel console ring, crash reports) to the Windows project folder. Read-only on the phone.
#
#   bash tools/redfin-pull-logs-wsl.sh [OUTDIR]     phone in TWRP; OUTDIR default
#                                                   /mnt/c/ClaudeProjects/iOS_Pixel5/logs/<time>
set -euo pipefail
cd "$(dirname "$0")/.."
W=${REDFIN_WORK:-$HOME/redfin-work}
IMG=$W/iosroot.img COPY=$W/iosroot-phone.img
PART=/dev/block/sda19
OUT=${1:-/mnt/c/ClaudeProjects/iOS_Pixel5/logs/$(date +%Y%m%d-%H%M%S)}
ADB=${ADB:-$(command -v adb.exe || command -v adb || true)}
[[ -n $ADB ]] || { echo "adb.exe not found: export ADB=/mnt/c/path/to/adb.exe"; exit 1; }
sh_() { "$ADB" shell "$@" </dev/null | tr -d '\r'; }
grep -qw hfsplus /proc/filesystems || { echo "no hfsplus: run tools/redfin-mkroot-wsl.sh hfsmod"; exit 1; }
[[ $("$ADB" get-state 2>/dev/null | tr -d '\r') == recovery ]] || { echo "phone not in TWRP"; exit 1; }
[[ $(sh_ readlink -f /dev/block/by-name/userdata) == "$PART" ]] || { echo "userdata is not $PART"; exit 1; }
mkdir -p "$OUT"

[[ -f $IMG ]] || { echo "no $IMG"; exit 1; }
# per-GiB checksums of the image as installed: wherever the image was built from, else recompute
SUMS=
for c in work/iosroot/iosroot.gib.sha256 "$W/iosroot.gib.sha256" \
	$(find "$HOME" -maxdepth 5 -name iosroot.gib.sha256 -newer "$IMG" 2>/dev/null); do
	[[ -f $c && ! $c -ot $IMG ]] && { SUMS=$c; break; }
done
if [[ -z $SUMS ]]; then
	echo "== no checksum list found: hashing $IMG (a minute or two)"
	SUMS=$W/iosroot.gib.sha256
	python3 -I - "$IMG" "$SUMS" <<'PY2'
import hashlib, sys
with open(sys.argv[1], 'rb') as f, open(sys.argv[2], 'w') as o:
    i = 0
    while True:
        h = hashlib.sha256(); n = 0
        while n < 1 << 30:
            c = f.read(1 << 22)
            if not c: break
            h.update(c); n += len(c)
        if not n: break
        o.write(f'{i} {h.hexdigest()}\n'); i += 1
PY2
fi
echo "  checksums: $SUMS"
echo "== copy of the image, then the GiBs that changed on the phone"
cp --sparse=always "$IMG" "$COPY"
n=0
while read -r i want <&3; do
	got=$(sh_ "dd if=$PART bs=4194304 skip=$((i * 256)) count=256 2>/dev/null | sha256sum" | cut -d' ' -f1)
	[[ $got == "$want" ]] && continue
	echo "  GiB $i changed: pulling"
	"$ADB" exec-out "dd if=$PART bs=4194304 skip=$((i * 256)) count=256 2>/dev/null" </dev/null |
		dd of="$COPY" bs=4194304 seek=$((i * 256)) conv=notrunc status=none
	n=$((n + 1))
done 3< "$SUMS"
echo "  pulled $n GiB"

echo "== kernel console ring (end of userdata)"
blocks=$(( $(sh_ blockdev --getsize64 $PART) / 4096 ))
"$ADB" exec-out "dd if=$PART bs=4096 skip=$((blocks - 1025)) count=1025 2>/dev/null" </dev/null > "$OUT/xnu-ring.bin"
python3 -I tools/sweet-log.py "$OUT/xnu-ring.bin" "$OUT/xnu.txt" || echo "  (sweet-log.py failed; raw ring kept)"
"$ADB" exec-out "dd if=$PART bs=4096 skip=$((blocks - 1025 - 64)) count=64 2>/dev/null" </dev/null | tr -d '\000' > "$OUT/shim.txt"

echo "== files from the iOS root"
M=$W/mnt-phone; mkdir -p "$M"
sudo mount -t hfsplus -o loop,ro,force "$COPY" "$M"
trap 'sudo umount "$M" 2>/dev/null || true' EXIT
V=$M/private/var
for f in local/wland.log local/wland.log.prev local/wland.boot; do
	sudo test -f "$V/$f" && sudo cp "$V/$f" "$OUT/${f##*/}" && echo "  $f"
done
sudo find "$V/mobile/Library/Logs/CrashReporter" "$V/root/Library/Logs/CrashReporter" "$V/db/diagnostics" \
	-maxdepth 1 -type f \( -name '*.ips' -o -name '*.crash' \) -printf '%T@ %p\n' 2>/dev/null |
	sort -rn | head -50 | cut -d' ' -f2- |	# newest 50 (the phone's clock may be off: no age filter)
	while read -r f; do sudo cp "$f" "$OUT/"; echo "  ${f#"$M"}"; done || true
sudo umount "$M"; trap - EXIT
sudo chown -R "$(id -u):$(id -g)" "$OUT" 2>/dev/null || true
ls -l "$OUT"
echo "logs: $OUT"
