#!/usr/bin/env python3
"""Live XNU console over USB Ethernet (bsd/dev/sweet_usb.c sends UDP to 192.168.7.1:5140).

  tools/flame-live.py [OUT.txt] [--secs N] [--grep REGEX]

Prints (and appends to OUT, default logs/live.txt) every datagram as it
arrives. The Mac side needs 192.168.7.1/24 on the "Sweet iOS (USB Ethernet)"
interface (networksetup -setmanual "Sweet iOS (USB Ethernet)" 192.168.7.1 255.255.255.0).
"""
import argparse, re, socket, sys, time

ap = argparse.ArgumentParser()
ap.add_argument('out', nargs='?', default='logs/live.txt')
ap.add_argument('--secs', type=float, default=0, help='stop after N seconds (0: run until ^C)')
ap.add_argument('--grep', help='only print lines matching this regex (all are saved)')
a = ap.parse_args()
pat = re.compile(a.grep) if a.grep else None
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 5140))
s.settimeout(1.0)
end = time.time() + a.secs if a.secs else None
n = 0
with open(a.out, 'ab') as f:
    while end is None or time.time() < end:
        try:
            data, src = s.recvfrom(65536)
        except socket.timeout:
            continue
        n += len(data)
        f.write(data)
        f.flush()
        text = data.decode(errors='replace')
        for line in text.splitlines():
            if not pat or pat.search(line):
                print(line, flush=True)
print(f'[flame-live: {n} bytes]', file=sys.stderr)
