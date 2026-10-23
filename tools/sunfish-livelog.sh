#!/bin/sh
# Keep the phone's USB Ethernet addressed across reboots and append its live
# kernel console (UDP 5140) to LOGFILE. Each time the interface (re)appears a
# "=== link up <time>" marker is written, so one file holds every boot.
#   tools/sunfish-livelog.sh LOGFILE
set -u
log=${1:?usage: $0 LOGFILE}
mac=02:00:5e:77:ee:01
socat -u udp-recv:5140,reuseaddr - >> "$log" &
trap 'kill $! 2>/dev/null' EXIT
while true; do
	ifname=$(ip -o link | grep -i "$mac" | awk -F': ' '{print $2}' | cut -d@ -f1)
	if [ -n "$ifname" ] && ! ip -br addr show "$ifname" | grep -q 192.168.7.1/; then
		nmcli dev set "$ifname" managed no 2>/dev/null || true
		sudo ip addr replace 192.168.7.1/24 dev "$ifname"
		sudo ip link set "$ifname" up
		echo "=== link up $(date +%T) on $ifname" >> "$log"
	fi
	sleep 1
done
