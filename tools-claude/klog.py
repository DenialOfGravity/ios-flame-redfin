#!/usr/bin/env python3
"""Read the running kernel's log ring through the file server's /dev/pmem.
usage: klog.py [TOTAL_PA]   (PA of _sweet_log_total; the ring pointer follows 8 bytes on)
  r9-r13 kernels: 0x101cee710   r14 (xnu 0915): 0x101d02710 (default); per build: builds/xnu/<ref>/KLOG_PA.txt
u-prof (2026-10-27): reads the 8-byte total first, then only the bytes in use (the whole ring once it wrapped)
in 1 MiB pieces, each tried 3 times with its own timeout, instead of one 4 MiB read."""
import struct, subprocess, sys, time
OUT = '/mnt/c/ClaudeProjects/iOS_Pixel5/logs/klog.txt'
TOTAL_PA = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x101d02710
SIZE = 4 << 20
PIECE = 1 << 20
TMP = '/tmp/klog.bin'


def rd(pa, n):
    for k in range(3):
        try:
            subprocess.run(['python3', '-I', 'tools/flame-files.py', 'read', '/dev/pmem', hex(pa), str(n), TMP],
                           check=True, timeout=30 + n // 50000, stdout=subprocess.DEVNULL)
            d = open(TMP, 'rb').read()
            if len(d) == n:
                return d
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            print('klog: read 0x%x+%d failed (%s), try %d' % (pa, n, type(e).__name__, k + 1), file=sys.stderr)
        time.sleep(1 + k)
    raise SystemExit('klog: /dev/pmem read 0x%x+%d failed 3 times' % (pa, n))


def ring(off, n):
    out = b''
    while n > 0:
        m = min(n, PIECE)
        out += rd(TOTAL_PA + 8 + off, m)
        off += m
        n -= m
    return out


total = struct.unpack('<Q', rd(TOTAL_PA, 8))[0]
if total <= SIZE:
    text = ring(0, total)
else:
    pos = total % SIZE
    text = ring(pos, SIZE - pos) + ring(0, pos)
open(OUT, 'wb').write(text)
print('log bytes written', total, '->', OUT)
