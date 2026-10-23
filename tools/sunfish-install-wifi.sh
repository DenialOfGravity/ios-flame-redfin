#!/bin/bash
# Wi-Fi at boot on the Pixel 4a: install wland + firmware and the launchd job
# org.iosonpixel.wland (`wland auto`: once per phone boot, log /var/local/wland.log).
# Firmware: modem from backup/modem_b.img (restore/fw/modempart), wlanmdsp/bdwlan from
# the factory vendor.img (restore/fw/vendor), rmtfs = backup/{modemst1,modemst2,fsg,fsc}.
# Reboot afterwards. Off: touch /var/local/wland.off or boot-arg sweetwifi=0.
set -euo pipefail
cd "$(dirname "$0")/.."
F() { python3 -I tools/flame-files.py "$@"; }
U=work/userland R=../restore/fw
for d in /var/local/fw /var/local/fw/modem /var/local/fw/rw; do F mkdir $d 755 >/dev/null 2>&1 || true; done
F mkdir /var/local/fw/rmtfs 700 >/dev/null 2>&1 || true
F put $U/stage/wland /var/local/bin/wland 755
F put $U/stage/netsvc /var/local/bin/netsvc 755
if [ -d $R/modempart/image ]; then
	for f in $R/modempart/image/modem.* $R/modempart/image/modemr.jsn $R/vendor/wlanmdsp.mbn \
		$R/vendor/modemuw.jsn $R/vendor/bdwlan-sunfish.bin $R/vendor/bdwlan-sunfish-EVT1.0.bin; do
		F put "$f" /var/local/fw/modem/$(basename "$f") 644 >/dev/null
	done
	for p in modemst1 modemst2 fsg fsc; do F put ../backup/$p.img /var/local/fw/rmtfs/$p.img 600 >/dev/null; done
fi
F get /System/Library/xpc/launchd.plist $U/launchd.plist.cur
python3 -I - "$U/launchd.plist.cur" "$U/launchd.plist.new" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
p['LaunchDaemons']['/System/Library/LaunchDaemons/org.iosonpixel.wland.plist'] = {
    'Label': 'org.iosonpixel.wland',
    'ProgramArguments': ['/var/local/bin/wland', 'auto'],
    'RunAtLoad': True, 'UserName': 'root',
    'EnvironmentVariables': {'PATH': '/var/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
}
plistlib.dump(p, open(sys.argv[2], 'wb'), fmt=plistlib.FMT_BINARY)
print('launchd jobs:', len(p['LaunchDaemons']))
PY
F put $U/launchd.plist.new /System/Library/xpc/launchd.plist 644
python3 -I tools/flame-cmd.py sync >/dev/null || true
echo "installed; reboot: wland starts ~at boot, Settings > Wi-Fi to join"
