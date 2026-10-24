#!/bin/bash
# Add Wi-Fi to the iOS root image in WSL (the Pixel 5 has no USB/SSH path from Windows yet, so
# this edits ~/redfin-work/iosroot.img; then `redfin-install-root-wsl.sh delta` writes the changed
# GiBs to the phone). Same files and launchd job as tools/sunfish-install-wifi.sh:
#   /var/local/bin/{wland,netsvc}           from the CI ios-userland artifact
#   /var/local/fw/modem/                    modem.mdt/.bNN, modemr.jsn (modem partition),
#                                           wlanmdsp.mbn, modemuw.jsn, bdwlan*-redfin.bin (vendor)
#   /var/local/fw/rmtfs/                    YOUR phone's modemst1/modemst2/fsg/fsc (backup\, private)
#   launchd job org.iosonpixel.wland        `wland auto` at boot (log /var/local/wland.log)
# Join a network in Settings > Wi-Fi. Off: boot-arg sweetwifi=0 or /var/local/wland.off.
#
#   bash tools/redfin-install-wifi-wsl.sh USERLAND.zip [FW_DIR] [BACKUP_DIR]
#     USERLAND.zip  the ios-userland artifact (e.g. /mnt/c/ClaudeProjects/iOS_Pixel5/ios-userland.zip)
#     FW_DIR        default /mnt/c/ClaudeProjects/iOS_Pixel5/ios-redfin-tree/ios-redfin/recon/fw
#     BACKUP_DIR    default /mnt/c/ClaudeProjects/iOS_Pixel5/ios-redfin-tree/ios-redfin/backup
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD W=${REDFIN_WORK:-$HOME/redfin-work}
IMG=$W/iosroot.img
WIN=/mnt/c/ClaudeProjects/iOS_Pixel5/ios-redfin-tree/ios-redfin
ZIP=${1:?usage: $0 USERLAND.zip [FW_DIR] [BACKUP_DIR]}
FW=${2:-$WIN/recon/fw} BK=${3:-$WIN/backup}
grep -qw hfsplus /proc/filesystems || { echo "no hfsplus: run tools/redfin-mkroot-wsl.sh hfsmod"; exit 1; }
[[ -f $IMG ]] || { echo "no $IMG"; exit 1; }

echo "== inputs"
U=$W/userland; rm -rf "$U"; mkdir -p "$U"
python3 -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$U"
for f in wland netsvc; do [[ -f $U/$f ]] || { echo "$f missing in $ZIP"; exit 1; }; done
modem=("$FW"/modem.mdt "$FW"/modem.b[0-9][0-9] "$FW"/modemr.jsn)
vendor=("$FW"/wlanmdsp.mbn "$FW"/modemuw.jsn "$FW"/bdwlan-redfin.bin)
for f in "${modem[@]}" "${vendor[@]}"; do
	[[ -f $f ]] || { echo "missing $f (re-run tools\\redfin-recon.ps1 twrp: it now pulls the vendor Wi-Fi files)"; exit 1; }
done
for p in modemst1 modemst2 fsg fsc; do [[ -f $BK/$p.img ]] || { echo "missing $BK/$p.img"; exit 1; }; done
echo "  userland: $(ls "$U" | tr '\n' ' ')"
echo "  firmware: ${#modem[@]} modem + ${#vendor[@]} vendor files; rmtfs from $BK"

echo "== mount the image"
M=$W/mnt; mkdir -p "$M"
sudo fsck.hfsplus -fy "$IMG" | grep -v 'Illegal name' | tail -1 || true
sudo mount -t hfsplus -o loop,force "$IMG" "$M"
trap 'sudo umount "$M" 2>/dev/null || true' EXIT
own() { sudo python3 -c 'import os, sys; u = int(sys.argv[1]); [os.chown(p, u, u) for p in sys.argv[2:]]' "$@"; }
put() {	# SRC DST MODE (owner root)
	sudo cp "$1" "$2"; sudo chmod "$3" "$2"; own 0 "$2"
}
V=$M/private/var/local
sudo mkdir -p "$V/bin" "$V/fw/modem" "$V/fw/rw" "$V/fw/rmtfs"
sudo chmod 755 "$V" "$V/bin" "$V/fw" "$V/fw/modem" "$V/fw/rw"; sudo chmod 700 "$V/fw/rmtfs"
own 0 "$V" "$V/bin" "$V/fw" "$V/fw/modem" "$V/fw/rw" "$V/fw/rmtfs"
put "$U/wland" "$V/bin/wland" 755
put "$U/netsvc" "$V/bin/netsvc" 755
for t in psx pstack oslog prefs openapp lsreg nettest; do [[ -f $U/$t ]] && put "$U/$t" "$V/bin/$t" 755; done
for f in "${modem[@]}" "${vendor[@]}" "$FW"/bdwlan-u-redfin.bin; do [[ -f $f ]] && put "$f" "$V/fw/modem/${f##*/}" 644; done
for p in modemst1 modemst2 fsg fsc; do put "$BK/$p.img" "$V/fw/rmtfs/$p.img" 600; done
echo "  /var/local: $(sudo find "$V" -type f | wc -l) files"

echo "== launchd job org.iosonpixel.wland"
sudo python3 -I - "$M/System/Library/xpc/launchd.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
p = plistlib.load(open(path, 'rb'))
p['LaunchDaemons']['/System/Library/LaunchDaemons/org.iosonpixel.wland.plist'] = {
    'Label': 'org.iosonpixel.wland',
    'ProgramArguments': ['/var/local/bin/wland', 'auto'],
    'RunAtLoad': True, 'UserName': 'root',
    'EnvironmentVariables': {'PATH': '/var/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
}
plistlib.dump(p, open(path, 'wb'), fmt=plistlib.FMT_BINARY)
print('  launchd jobs:', len(p['LaunchDaemons']))
PY

echo "== configd preferences"
# A root that booted before en0 existed has a preferences.plist with no network services; configd never
# adds one for en0 later, so iOS never does DHCP on Wi-Fi (flame 2026-10-22, redfin 2026-10-24). Move it
# aside: configd writes a default configuration with a Wi-Fi service on the next boot.
SC=$M/private/var/preferences/SystemConfiguration/preferences.plist
if sudo test -f "$SC" && ! sudo python3 -I -c 'import plistlib, sys; sys.exit(0 if plistlib.load(open(sys.argv[1], "rb")).get("NetworkServices") else 1)' "$SC"; then
	sudo mv "$SC" "$SC.pre-wifi"
	echo "  preferences.plist had no network services: moved to preferences.plist.pre-wifi"
else
	echo "  ok (none yet, or it has network services)"
fi

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
echo "wifi: added to $IMG. Next (phone in TWRP): bash tools/redfin-install-root-wsl.sh delta"
