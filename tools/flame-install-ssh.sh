#!/bin/bash
# Install SSH (dropbear) + dash + toybox into the running iOS root over the file server
# (tools/flame-files.py, FlameBridge). Then reboot: launchd reads its job cache at boot.
#
#   tools/flame-install-ssh.sh
#
# Binaries: work/userland/stage (built from work/userland/src, signed ad hoc). Key:
# work/userland/ssh/id_ed25519 (ssh -i that -p 2222 root@127.0.0.1 through FlameBridge).
set -euo pipefail
cd "$(dirname "$0")/.."
F="python3 tools/flame-files.py"
U=work/userland
$F mkdir /var/local 755
$F mkdir /var/local/bin 755
$F mkdir /private/etc/dropbear 700
$F mkdir /var/root/.ssh 700
for b in dropbearmulti dash toybox; do $F put $U/stage/$b /var/local/bin/$b 755; done
$F rm /var/local/bin/dropbear 2>/dev/null || true
$F link /var/local/bin/dropbearmulti /var/local/bin/dropbear
$F link /var/local/bin/dropbearmulti /var/local/bin/scp || true
for a in ls cat cp mv rm mkdir rmdir ln chmod chown ps kill grep sed head tail wc find xargs \
	sort uniq cut tr df du mount uname date env id whoami hexdump od dd sleep touch stat \
	which file tee printf echo true false test basename dirname readlink realpath uptime \
	free top hostname nc ping ifconfig netstat dmesg sync md5sum sha1sum sha256sum tar gzip; do
	$F link /var/local/bin/toybox /var/local/bin/$a >/dev/null 2>&1 || true
done
$F link /var/local/bin/dash /bin/sh || echo "(/bin/sh exists)"
$F put $U/ssh/id_ed25519.pub /var/root/.ssh/authorized_keys 600

# launchd job (cache: /System/Library/xpc/launchd.plist; original kept as .orig on the phone)
$F get /System/Library/xpc/launchd.plist $U/launchd.plist.cur
python3 - "$U/launchd.plist.cur" "$U/launchd.plist.new" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
p['LaunchDaemons']['/System/Library/LaunchDaemons/org.iosonpixel.dropbear.plist'] = {
    'Label': 'org.iosonpixel.dropbear',
    'ProgramArguments': ['/var/local/bin/dropbear', '-F', '-E', '-R', '-p', '22'],
    'RunAtLoad': True, 'KeepAlive': True, 'UserName': 'root',
    'EnvironmentVariables': {'PATH': '/var/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
    'StandardErrorPath': '/var/local/dropbear.log',
}
plistlib.dump(p, open(sys.argv[2], 'wb'), fmt=plistlib.FMT_BINARY)
print('launchd jobs:', len(p['LaunchDaemons']))
PY
$F put $U/launchd.plist.orig /System/Library/xpc/launchd.plist.orig 644 2>/dev/null || true
$F put $U/launchd.plist.new /System/Library/xpc/launchd.plist 644
echo "installed; reboot the phone (tools/flame-cmd.py reboot) and boot again for launchd to start dropbear"
