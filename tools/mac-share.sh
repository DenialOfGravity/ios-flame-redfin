#!/bin/bash
# Share the Mac's internet with the phone over the USB Ethernet link (phone 192.168.7.2, Mac 192.168.7.1),
# without macOS Internet Sharing (that would re-address the link). Run with sudo:
#   sudo tools/mac-share.sh        # on (again after a Mac reboot or a network change)
#   sudo tools/mac-share.sh off
# NAT goes into its own pf anchor (com.apple/sweet-share, which /etc/pf.conf's nat-anchor "com.apple/*"
# includes), so the rest of the firewall is left alone.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
if [ "${1:-}" = off ]; then
	pfctl -a com.apple/sweet-share -F all 2>/dev/null || true
	sysctl -w net.inet.ip.forwarding=0
	echo "phone internet sharing off"
	exit 0
fi
out=$(route -n get default | awk '/interface:/ {print $2}')
[ -n "$out" ] || { echo "no default route on the Mac"; exit 1; }
sysctl -w net.inet.ip.forwarding=1
echo "nat on $out inet from 192.168.7.0/24 to any -> ($out)" | pfctl -a com.apple/sweet-share -f -
pfctl -E 2>&1 | grep -v "^No ALTQ\|^ALTQ" || true
echo "phone internet sharing on: 192.168.7.0/24 -> $out"
pfctl -a com.apple/sweet-share -s nat
