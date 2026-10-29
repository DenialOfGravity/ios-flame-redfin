#!/usr/bin/env python3
"""sweetmon-client.py: minimal test client for phone/tools/sweetmon (protocol: docs/redfin/sweetmon.md).
usage: sweetmon-client.py [-H HOST] [-p PORT] [-k TOKEN|-K KEYFILE] [-t SECS] [-o DIR] [CMD ...]
  Connects, authenticates, sends each CMD (one argv word per command line, e.g. 'rate 500 1' 'klog 0x101d0ef08'),
  prints a one-line summary of every frame for SECS seconds (default 5; 0 = until the first E frame after a trace).
  T chunks are joined per trace id and written to DIR/trace-<id>.lz4 and, decompressed (python lz4 if present, else
  tools/lz4py.py), DIR/trace-<id>.swtr (kdebug) or .bin (pmem)."""
import argparse, json, os, socket, struct, sys, time

ap = argparse.ArgumentParser()
ap.add_argument('-H', '--host', default='192.168.7.2')
ap.add_argument('-p', '--port', type=int, default=5150)
ap.add_argument('-k', '--token', default=None)
ap.add_argument('-K', '--keyfile', default=None)
ap.add_argument('-t', '--secs', type=float, default=5)
ap.add_argument('-o', '--out', default='.')
ap.add_argument('-q', '--quiet', action='store_true', help='no per-frame lines for S/K/P')
ap.add_argument('cmds', nargs='*')
a = ap.parse_args()
tok = a.token or (open(a.keyfile).read().strip() if a.keyfile else None)


def lz4_decompress(d):
    try:
        import lz4.frame
        return lz4.frame.decompress(d)
    except ImportError:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import lz4py
        return lz4py.decompress(d)


s = socket.create_connection((a.host, a.port), timeout=10)
s.settimeout(0.5)


def send(cmd):
    b = cmd.encode()
    s.sendall(struct.pack('<IB', len(b) + 1, ord('C')) + b)


buf = b''
if tok:
    send('auth ' + tok)
for c in a.cmds:
    send(c)
traces, counts, nbytes = {}, {}, 0
t0 = time.time()
end = t0 + a.secs if a.secs > 0 else None
done = False
while not done and (end is None or time.time() < end):
    try:
        d = s.recv(1 << 20)
    except socket.timeout:
        continue
    if not d:
        print('closed by phone')
        break
    buf += d
    nbytes += len(d)
    while len(buf) >= 5:
        n = struct.unpack_from('<I', buf)[0]
        if len(buf) < 4 + n:
            break
        ty, p = chr(buf[4]), buf[5:4 + n]
        buf = buf[4 + n:]
        counts[ty] = counts.get(ty, 0) + 1
        ts = '%7.3f' % (time.time() - t0)
        if ty in 'HRSFE':
            j = json.loads(p)
            if ty == 'S':
                if not a.quiet:
                    busy = [round(100 * (c[0] + c[1] + c[3]) / max(1, sum(c))) for c in j.get('cpu', [])]
                    top = ' '.join('%s:%.0f' % (r[1], r[2]) for r in j.get('procs', [])[:4])
                    print(ts, 'S busy%%=%s temp_max=%s self=%s nproc=%s top: %s' % (busy, j.get('temp', {}).get('max'),
                          j.get('self'), j.get('nproc'), top))
            else:
                print(ts, ty, json.dumps(j))
            if ty == 'E':
                z = traces.pop(j['id'], b'')
                base = os.path.join(a.out, 'trace-%d' % j['id'])
                open(base + '.lz4', 'wb').write(z)
                if z and 'error' not in j:
                    raw = lz4_decompress(z)
                    ext = '.swtr' if j['kind'] == 'kdebug' else '.bin'
                    open(base + ext, 'wb').write(raw)
                    print(ts, 'wrote %s%s: %d bytes (E says %d)%s' % (base, ext, len(raw), j['bytes'],
                          '' if len(raw) == j['bytes'] else ' MISMATCH'))
                if a.secs == 0:
                    done = True
        elif ty == 'K':
            pos = struct.unpack_from('<Q', p)[0]
            if not a.quiet:
                tail = p[8:].rstrip(b'\n').rsplit(b'\n', 1)[-1][:100].decode('utf-8', 'replace')
                print(ts, 'K pos=%d n=%d | %s' % (pos, len(p) - 8, tail))
        elif ty == 'T':
            tid, seq = struct.unpack_from('<II', p)
            traces[tid] = traces.get(tid, b'') + p[8:]
            print(ts, 'T id=%d seq=%d n=%d' % (tid, seq, len(p) - 8))
        elif ty == 'P':
            if not a.quiet and counts['P'] % 16 == 1:
                print(ts, 'P x%d' % counts['P'])
        else:
            print(ts, ty, len(p), 'bytes')
el = time.time() - t0
print('frames %s, %d bytes in %.1f s (%.2f MB/s)' % (counts, nbytes, el, nbytes / el / 1e6))
