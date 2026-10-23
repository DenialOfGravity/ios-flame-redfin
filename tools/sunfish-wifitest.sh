#!/bin/bash
# One Wi-Fi join test on the Pixel 4a: install wland from a CI run, write /var/local/wlan.conf (+ optional test
# hooks), reboot, let wland join at boot, then delete wlan.conf and verify it is gone. Copies the log to logs/.
#
#   WIFI_PSK=... tools/sunfish-wifitest.sh RUNID NAME [steps-hex] [scan-freqs]
#
# The password only comes in through WIFI_PSK and only lands on the phone, for the length of the test.
# Starts only with the phone reachable over SSH; one instance at a time; recovers with a sweetwifi=0 boot if
# the phone does not come back, so wlan.conf never stays behind.
set -uo pipefail
cd "$(dirname "$0")/.."
run=$1 name=$2 steps=${3:-} freqs=${4:-}
K=${KERNEL:-work/kernel26/kernel.development.sweet}
SSID=${WIFI_SSID:-Johann}
exec 9>/tmp/sunfish-wifitest.lock
flock -n 9 || { echo "another wifi test is running"; exit 1; }
[ -n "${WIFI_PSK:-}" ] || { echo "WIFI_PSK not set"; exit 1; }
ssh_() { timeout 15 tools/sunfish-ssh "$@"; }
ssh_ true 2>/dev/null || { echo "phone not reachable over SSH: not starting"; exit 1; }

D=$(mktemp -d)
gh run download "$run" -n ios-userland -D "$D" >/dev/null || { echo "download failed"; exit 1; }
python3 -I tools/flame-files.py put "$D/wland" /var/local/bin/wland 755 | grep -q OK || { echo "install failed"; exit 1; }
rm -rf "$D"

hooks="rm -f /var/local/wlan-steps.conf /var/local/wlan-scan.conf"
[ -n "$steps" ] && hooks="$hooks; echo $steps > /var/local/wlan-steps.conf"
[ -n "$freqs" ] && hooks="$hooks; printf '%s\n' $freqs > /var/local/wlan-scan.conf"
ssh_ "umask 077; printf 'ssid=%s\npsk=%s\n' '$SSID' '$WIFI_PSK' > /var/local/wlan.conf; $hooks; mv /var/local/wland.log /var/local/wland.log.prev 2>/dev/null; ls /var/local/wlan.conf" >/dev/null ||
	{ echo "could not write wlan.conf"; exit 1; }

python3 -I tools/flame-cmd.py reboot >/dev/null 2>&1
for i in $(seq 60); do fastboot devices | grep -q fastboot && break; sleep 3; done
fastboot getvar battery-voltage 2>&1 | head -1
echo "=== $name wifi test steps=${steps:-default} freqs=${freqs:-all} $(date +%T)" >> ../logs/usb-live.log
timeout 150 tools/sunfish-boot.sh "$name" "$K" flamereboot=600 sweettouch=2 >/dev/null 2>&1

ok=0
for i in $(seq 30); do ssh_ true 2>/dev/null && { ok=1; break; }; sleep 5; done
if [ $ok = 1 ]; then
	sleep 70
	ssh_ 'rm -f /var/local/wlan.conf; ls /var/local/wlan.conf 2>&1 | tail -1' || ok=0
fi
if [ $ok = 0 ]; then
	echo "phone unreachable: recovering with sweetwifi=0"
	for i in $(seq 200); do fastboot devices | grep -q fastboot && break; sleep 5; done
	echo "=== ${name}r recovery sweetwifi=0 $(date +%T)" >> ../logs/usb-live.log
	timeout 150 tools/sunfish-boot.sh "${name}r" "$K" flamereboot=600 sweettouch=2 sweetwifi=0 >/dev/null 2>&1
	for i in $(seq 40); do ssh_ true 2>/dev/null && break; sleep 5; done
	ssh_ 'rm -f /var/local/wlan.conf; ls /var/local/wlan.conf 2>&1 | tail -1'
fi
ssh_ 'cat /var/local/wland.log' > "../logs/wland-$name.log" 2>/dev/null
grep -aE "steps|vdev:|scan: |radio: join|join: |PD FAILURE|associated|4-way|lease|dhcp" "../logs/wland-$name.log" | head -20
echo "done $(date +%T)"
