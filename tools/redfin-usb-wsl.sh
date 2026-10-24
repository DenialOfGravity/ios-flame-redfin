#!/bin/bash
# USB Ethernet to the phone from WSL (Windows has no CDC-ECM driver; usbipd-win passes the device to
# WSL, whose cdc_ether drives it). Brings up 192.168.7.1/24 on the phone's link and shows the live
# kernel log (sweet_usb streams the console ring to 192.168.7.1:5140 UDP), saving it to
# /mnt/c/ClaudeProjects/iOS_Pixel5/logs/live-<time>.txt.
#
# Windows PowerShell (admin, once):   usbipd list            -> the "Sweet iOS (USB Ethernet)" / 1209:0001 BUSID
#                                     usbipd bind --busid X
# each boot (normal PowerShell):      usbipd attach --wsl --busid X
# then WSL:                           bash tools/redfin-usb-wsl.sh        (Ctrl-C stops the log)
#
# Then also: python3 tools/flame-files.py ...   (file server, 192.168.7.2:2223)
set -euo pipefail
LOG=/mnt/c/ClaudeProjects/iOS_Pixel5/logs/live-$(date +%Y%m%d-%H%M%S).txt
sudo modprobe vhci_hcd 2>/dev/null || true
sudo modprobe cdc_ether
echo "== waiting for the phone's USB Ethernet (host MAC 02:00:5e:77:ee:01)"
ifc=
for _ in $(seq 60); do
	for d in /sys/class/net/*; do
		[[ $(cat "$d/address" 2>/dev/null) == 02:00:5e:77:ee:01 ]] && { ifc=${d##*/}; break 2; }
	done
	sleep 1
done
[[ -n $ifc ]] || { echo "no interface: is the device attached (usbipd attach --wsl)? lsusb:"; lsusb 2>/dev/null || true; exit 1; }
sudo ip addr flush dev "$ifc"
sudo ip addr add 192.168.7.1/24 dev "$ifc"
sudo ip link set "$ifc" up
echo "  $ifc up, 192.168.7.1 -> phone 192.168.7.2"
ping -c 2 -W 2 192.168.7.2 || echo "  (no ping reply yet; the log may still arrive)"
echo "== live kernel log -> $LOG (Ctrl-C to stop)"
python3 -I -u - "$LOG" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 5140))
with open(sys.argv[1], 'ab') as f:
    try:
        while True:
            d, _ = s.recvfrom(65536)
            f.write(d); f.flush()
            sys.stdout.write(d.decode('utf-8', 'replace').replace('\r', ''))
    except KeyboardInterrupt:
        pass
PY
