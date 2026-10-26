#!/bin/bash
# Install fastrpcd and the files the ADSP's sensors PD reads (WS-D) -- in WSL, like redfin-install-wifi-wsl.sh.
#
#   /var/local/bin/fastrpcd                    from the CI ios-userland artifact
#   /private/var/local/hexagon/                the served tree (fastrpcd maps the DSP's paths onto it):
#     vendor/etc/sensors/config/               recon/fw-adsp/hexagon (the phone's /vendor/etc/sensors/config)
#     vendor/etc/sensors/sns_reg_config        recon/fw-adsp/hexagon
#     vendor/etc/acdbdata/                     recon/fw-adsp/hexagon (if captured)
#     usr/lib/qcom/adsp/                       recon/fw-adsp/hexagon (the phone's /vendor/dsp/adsp, if captured)
#     persist/sensors/                         recon/persist/sensors (registry: the only part the DSP writes)
#     sys/devices/soc0/<attribute>             recon/fw-adsp/soc0.txt, one file per attribute
#   launchd job org.iosonpixel.fastrpcd        fastrpcd at boot, restarted when the DSP comes back (log
#                                              /var/local/fastrpcd.log; off: /var/local/fastrpcd.off)
# Vendor files never go into git: they come from YOUR phone's dumps on the PC.
#
#   bash tools/redfin-install-hexagon-wsl.sh USERLAND.zip [ADSP_DIR] [PERSIST_DIR]
#       edits ~/redfin-work/iosroot.img (then: bash tools/redfin-install-root-wsl.sh delta, phone in TWRP)
#   bash tools/redfin-install-hexagon-wsl.sh --live USERLAND.zip [ADSP_DIR] [PERSIST_DIR]
#       pushes the binary and the tree to the RUNNING phone with tools/flame-files.py (PHONE_FILES_HOST);
#       the launchd job needs the image mode once (or start it by hand: /var/local/bin/fastrpcd -v)
#   bash tools/redfin-install-hexagon-wsl.sh --stage-only [ADSP_DIR] [PERSIST_DIR]
#       only builds the tree in ~/redfin-work/hexagon (to look at it)
#
#     USERLAND.zip  the ios-userland artifact (e.g. /mnt/c/ClaudeProjects/iOS_Pixel5/ios-userland.zip)
#     ADSP_DIR      default /mnt/c/ClaudeProjects/iOS_Pixel5/ios-redfin-tree/ios-redfin/recon/fw-adsp
#     PERSIST_DIR   default /mnt/c/ClaudeProjects/iOS_Pixel5/ios-redfin-tree/ios-redfin/recon/persist/sensors
#
# recon/fw-adsp/hexagon may be laid out like the phone (vendor/etc/sensors/..., vendor/dsp/adsp, ...) or like
# hexagonrpcd's -R directory (sensors/config, sensors/sns_reg.conf, acdb/, dsp/, socinfo/); both are understood.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD W=${REDFIN_WORK:-$HOME/redfin-work}
IMG=$W/iosroot.img
WIN=/mnt/c/ClaudeProjects/iOS_Pixel5/ios-redfin-tree/ios-redfin
MODE=image
case ${1:-} in --live) MODE=live; shift;; --stage-only) MODE=stage; shift;; esac
if [[ $MODE != stage ]]; then
	ZIP=${1:?usage: $0 [--live|--stage-only] USERLAND.zip [ADSP_DIR] [PERSIST_DIR]}; shift
fi
ADSP=${1:-$WIN/recon/fw-adsp} PERSIST=${2:-$WIN/recon/persist/sensors}
HEX=$ADSP/hexagon

echo "== stage the served tree in $W/hexagon"
S=$W/hexagon; rm -rf "$S"; mkdir -p "$S"
[[ -d $HEX ]] || { echo "missing $HEX (the recon of the phone's /vendor/etc/sensors etc.)"; exit 1; }
copydir() {	# SRC DST: contents of SRC into DST (if SRC exists)
	[[ -d $1 ]] || return 0
	mkdir -p "$2"; cp -R "$1"/. "$2"/
}
if [[ -d $HEX/vendor || -d $HEX/system/vendor ]]; then
	echo "  layout: like the phone"
	copydir "$HEX/system/vendor" "$S/vendor"
	copydir "$HEX/vendor" "$S/vendor"
	copydir "$HEX/usr" "$S/usr"
	copydir "$HEX/sys" "$S/sys"
	copydir "$HEX/persist" "$S/persist"
	copydir "$HEX/mnt/vendor/persist" "$S/persist"
	# Android keeps the DSP libraries in /vendor/dsp/adsp (or /vendor/lib/rfsa/adsp); fastrpcd's ADSP_LIBRARY_PATH
	# also looks there, but /usr/lib/qcom/adsp is the hexagonrpcd place: link it if it is missing
	[[ -d $S/usr/lib/qcom/adsp ]] || { [[ -d $S/vendor/dsp/adsp ]] && copydir "$S/vendor/dsp/adsp" "$S/usr/lib/qcom/adsp"; } || true
elif [[ -d $HEX/sensors ]]; then
	echo "  layout: hexagonrpcd -R"
	copydir "$HEX/sensors/config" "$S/vendor/etc/sensors/config"
	for f in sns_reg.conf sns_reg_config; do
		[[ -f $HEX/sensors/$f ]] && { mkdir -p "$S/vendor/etc/sensors"; cp "$HEX/sensors/$f" "$S/vendor/etc/sensors/sns_reg_config"; }
	done
	copydir "$HEX/sensors/registry" "$S/persist/sensors/registry/registry"
	copydir "$HEX/acdb" "$S/vendor/etc/acdbdata"
	if [[ -d $HEX/dsp/adsp ]]; then copydir "$HEX/dsp/adsp" "$S/usr/lib/qcom/adsp"; else copydir "$HEX/dsp" "$S/usr/lib/qcom/adsp"; fi
	copydir "$HEX/socinfo" "$S/sys/devices/soc0"
else
	echo "$HEX: neither vendor/ nor sensors/ inside; found:"; ls -la "$HEX"; exit 1
fi
# the writable registry: the phone's /mnt/vendor/persist/sensors
if [[ -d $PERSIST ]]; then
	copydir "$PERSIST" "$S/persist/sensors"
else
	echo "  WARNING: no $PERSIST: the DSP starts with an empty registry (it writes a new one)"
fi
mkdir -p "$S/persist/sensors/registry/registry" "$S/vendor/etc/sensors/config" "$S/sys/devices/soc0" \
	"$S/usr/lib/qcom/adsp" "$S/vendor/etc/acdbdata"
# soc0.txt -> one file per attribute. Understood: "/sys/devices/soc0/soc_id:434" (grep . *), "soc_id: 434",
# "soc_id=434", and head's "==> /sys/devices/soc0/soc_id <==" followed by the value
SOC=""; for f in "$ADSP/soc0.txt" "$HEX/soc0.txt" "$ADSP/../soc0.txt"; do [[ -f $f ]] && { SOC=$f; break; }; done
if [[ -n $SOC ]]; then
	python3 -I - "$SOC" "$S/sys/devices/soc0" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
vals, pending = {}, None
for raw in open(src, encoding='utf-8', errors='replace').read().replace('\r', '').split('\n'):
    line = raw.strip()
    m = re.match(r'^==> (.*) <==$', line)
    if m:
        pending = os.path.basename(m.group(1)); continue
    if not line:
        continue
    if pending is not None:
        vals[pending] = line; pending = None; continue
    m = re.match(r'^(?:/sys/devices/soc0/)?([A-Za-z0-9_]+)\s*[:=]\s*(.*)$', line)
    if m:
        vals[m.group(1)] = m.group(2)
for k, v in sorted(vals.items()):
    with open(os.path.join(dst, k), 'w') as f:
        f.write(v + '\n')
print(f'  soc0: {len(vals)} attributes from {src}: ' + ' '.join(f'{k}={v}' for k, v in sorted(vals.items()) if k in ('soc_id', 'revision', 'platform_subtype', 'platform_subtype_id', 'platform_version', 'machine')))
PY
else
	echo "  WARNING: no soc0.txt in $ADSP: /sys/devices/soc0 is empty"
fi
find "$S" -type d -exec chmod 755 {} +; find "$S" -type f -exec chmod 644 {} +
for d in vendor/etc/sensors/config vendor/etc/acdbdata usr/lib/qcom/adsp persist/sensors sys/devices/soc0; do
	printf '  %-28s %5s files\n' "$d" "$(find "$S/$d" -type f | wc -l)"
done
[[ -f $S/vendor/etc/sensors/sns_reg_config ]] || echo "  WARNING: no vendor/etc/sensors/sns_reg_config"
[[ -n $(ls -A "$S/vendor/etc/sensors/config") ]] || { echo "no sensor config files: the DSP would die as before"; exit 1; }
[[ $MODE == stage ]] && { echo "staged: $S"; exit 0; }

echo "== inputs"
U=$W/userland; rm -rf "$U"; mkdir -p "$U"
python3 -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$U"
[[ -f $U/fastrpcd ]] || { echo "fastrpcd missing in $ZIP (CI userland run with phone/fastrpc)"; exit 1; }
[[ -f $U/BUILD.txt ]] && sed 's/^/  /' "$U/BUILD.txt"

if [[ $MODE == live ]]; then
	echo "== push to the running phone (tools/flame-files.py, ${PHONE_FILES_HOST:-192.168.7.2})"
	F="python3 -I $REPO/tools/flame-files.py"
	$F mkdir /private/var/local 755 || true
	$F mkdir /private/var/local/bin 755 || true
	$F put "$U/fastrpcd" /private/var/local/bin/fastrpcd 755
	(cd "$S" && find . -type d | sort) | while read -r d; do $F mkdir "/private/var/local/hexagon/${d#./}" 755 >/dev/null || true; done
	(cd "$S" && find . -type f | sort) | while read -r f; do $F put "$S/${f#./}" "/private/var/local/hexagon/${f#./}" 644 >/dev/null; done
	echo "fastrpcd + tree pushed. Start it on the phone: /var/local/bin/fastrpcd -v (log on stderr)"
	exit 0
fi

grep -qw hfsplus /proc/filesystems || { echo "no hfsplus: run tools/redfin-mkroot-wsl.sh hfsmod"; exit 1; }
[[ -f $IMG ]] || { echo "no $IMG"; exit 1; }
echo "== mount the image"
M=$W/mnt; mkdir -p "$M"
sudo fsck.hfsplus -fy "$IMG" | grep -v 'Illegal name' | tail -1 || true
sudo mount -t hfsplus -o loop,force "$IMG" "$M"
trap 'sudo umount "$M" 2>/dev/null || true' EXIT
own() { sudo python3 -c 'import os, sys; u = int(sys.argv[1]); [os.chown(p, u, u) for p in sys.argv[2:]]' "$@"; }
V=$M/private/var/local
sudo mkdir -p "$V/bin"; sudo chmod 755 "$V" "$V/bin"; own 0 "$V" "$V/bin"
sudo cp "$U/fastrpcd" "$V/bin/fastrpcd"; sudo chmod 755 "$V/bin/fastrpcd"; own 0 "$V/bin/fastrpcd"
# the tree: replaced, except a registry the DSP has already written on the phone (kept, it is newer)
if sudo test -d "$V/hexagon/persist/sensors/registry/registry" && [[ -n $(sudo ls -A "$V/hexagon/persist/sensors/registry/registry") ]]; then
	echo "  keeping the phone's registry (hexagon/persist/sensors/registry/registry); delete it to reinstall"
	sudo mv "$V/hexagon/persist" "$W/persist.keep.$$"
	sudo rm -rf "$V/hexagon"; sudo cp -R "$S" "$V/hexagon"
	sudo rm -rf "$V/hexagon/persist"; sudo mv "$W/persist.keep.$$" "$V/hexagon/persist"
else
	sudo rm -rf "$V/hexagon"; sudo cp -R "$S" "$V/hexagon"
fi
sudo python3 -I -c 'import os, sys
for d, ds, fs in os.walk(sys.argv[1]):
    os.chown(d, 0, 0)
    for f in fs: os.lchown(os.path.join(d, f), 0, 0)' "$V/hexagon"
echo "  /private/var/local/hexagon: $(sudo find "$V/hexagon" -type f | wc -l) files"

echo "== launchd job org.iosonpixel.fastrpcd"
sudo python3 -I - "$M/System/Library/xpc/launchd.plist" "$REPO/phone/fastrpc/org.iosonpixel.fastrpcd.plist" <<'PY'
import plistlib, sys
path, job = sys.argv[1], sys.argv[2]
p = plistlib.load(open(path, 'rb'))
p['LaunchDaemons']['/System/Library/LaunchDaemons/org.iosonpixel.fastrpcd.plist'] = plistlib.load(open(job, 'rb'))
plistlib.dump(p, open(path, 'wb'), fmt=plistlib.FMT_BINARY)
print('  launchd jobs:', len(p['LaunchDaemons']))
PY

sudo umount "$M"; trap - EXIT
sudo fsck.hfsplus -fy "$IMG" | grep -v 'Illegal name' | tail -1 || true
echo "== per-GiB SHA-256"; mkdir -p "$REPO/work/iosroot"
python3 - "$IMG" "$REPO/work/iosroot/iosroot.gib.sha256" <<'PY'
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
print(f'  {sys.argv[2]}: {i} GiB')
PY
echo "hexagon: added to $IMG. Next (phone in TWRP): bash tools/redfin-install-root-wsl.sh delta"
