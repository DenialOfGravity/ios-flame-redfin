#!/usr/bin/env python3
"""klog-tail.py TOTAL_PA [BYTES]: the last BYTES (default 65536) of the running kernel's log ring to stdout, with two
small /dev/pmem reads instead of klog.py's 4 MiB (run from the repo, as klog.py)."""
import struct, subprocess, sys, tempfile, os
PA = int(sys.argv[1], 0)
WANT = int(sys.argv[2], 0) if len(sys.argv) > 2 else 65536
SIZE = 4 << 20


def rd(off, n):
    with tempfile.NamedTemporaryFile(delete=False) as t:
        path = t.name
    try:
        subprocess.run(['python3', '-I', 'tools/flame-files.py', 'read', '/dev/pmem', hex(off), str(n), path], check=True,
                       stdout=subprocess.DEVNULL)
        return open(path, 'rb').read()
    finally:
        os.unlink(path)


total = struct.unpack('<Q', rd(PA, 8))[0]
n = (min(WANT, total, SIZE) + 3) & ~3
if n > total:
    n = total & ~3
end = total % SIZE
start = (total - n) % SIZE
if start < end or end == 0:
    data = rd(PA + 8 + start, n)
else:
    data = rd(PA + 8 + start, SIZE - start) + rd(PA + 8, end)
sys.stdout.buffer.write(data)
