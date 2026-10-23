#!/bin/bash
# Share this Linux PC's internet with the phone over the USB Ethernet link (phone 192.168.7.2, PC 192.168.7.1).
# Linux counterpart of mac-share.sh. Run with sudo:
#   sudo tools/linux-share.sh        # on (again after a reboot)
#   sudo tools/linux-share.sh off
# NAT lives in its own nft table (ip sweet_share); with Docker's FORWARD policy DROP, two rules in DOCKER-USER
# (Docker's chain for user rules) let the phone's traffic through. Nothing else in the firewall is touched.
# On the phone afterwards: `netsvc up` (publishes ue0 as the primary network service, DNS 1.1.1.1).
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
NET=192.168.7.0/24
fwd_rules() {	# $1 = -I or -D
	iptables "$1" DOCKER-USER -s $NET -j ACCEPT
	iptables "$1" DOCKER-USER -d $NET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}
if [ "${1:-}" = off ]; then
	nft delete table ip sweet_share 2>/dev/null || true
	iptables -L DOCKER-USER -n >/dev/null 2>&1 && { fwd_rules -D 2>/dev/null || true; fwd_rules -D 2>/dev/null || true; }
	echo "phone internet sharing off"
	exit 0
fi
sysctl -qw net.ipv4.ip_forward=1
nft delete table ip sweet_share 2>/dev/null || true
nft -f - <<EOF
table ip sweet_share {
	chain post {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr $NET ip daddr != $NET masquerade
	}
	chain fwd {
		type filter hook forward priority filter - 1; policy accept;
		ip saddr $NET accept
		ip daddr $NET ct state related,established accept
	}
}
EOF
if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
	fwd_rules -D 2>/dev/null || true
	fwd_rules -I
fi
echo "phone internet sharing on ($NET via $(ip route show default | awk '{print $5; exit}'))"
