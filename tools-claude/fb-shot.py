#!/usr/bin/env python3
"""fb-shot.py RAW PNG [STEP]: panel-buffer dump (/dev/pmem 0xa0000000, 1088x2340 BGRA, stride 4352; same layout as
agent/tmp/fb2png.py) -> PNG (every STEP-th pixel, default 3), then print one word CLASS:DIST:LUM
  CLASS = nearest reference in tools-claude/fbref/*.feat (mean abs luminance difference on a 25x35 grid of
          the area below the status bar) when DIST <= 15 (page1 vs page2 is ~33), else 'dark' (LUM < 25) or 'other'.
fb-shot.py --mkref NAME RAW|PNG  store the grid as tools-claude/fbref/NAME.feat (PNG: one this script wrote, step 3)
fb-shot.py RAW PNG STEP WxH:STRIDE   RAW is a direct-scanout slot surface (e.g. 1125x2436:4608 BGRA, rkernel 0975+
          sweetscanout=2, `p scanout 1`): it is sampled nearest-neighbour into the panel's 1080x2340 geometry, so the
          PNG and the CLASS grid match the old panel-buffer shots and the fbref/*.feat references.
          (A RAW of at least 4608*2436 bytes without WxH:STRIDE is taken as 1125x2436:4608.)
fb-shot.py --where REGS [MONKLOG]  which buffer the MDP scans now. REGS = 64 bytes of VIG0's registers
          (flame-files.py read /dev/pmem 0x0ae05000 64 REGS; read-only, as `p mdp dump`): SRC0_ADDR +0x14, YSTRIDE0
          +0x24. Prints "direct PA LEN WxH:STRIDE slotN" (a scanout slot surface is latched) or "blit PA LEN -"
          (the old panel buffer 0xa0000000: scanout off, or the panel-buffer path after a non-slot frame).
          MONKLOG (sweetmon's klog file) gives the slot's "SWEET SURF: scanout slot N (..., PA X) for a WxH surface"
          line; default 1125x2436."""
import json, os, re, struct, sys, zlib

W, H, S = 1088, 2340, 4352
PW, PH = 1080, 2340	# panel pixels (grid and PNG coordinates)
SRC = None	# None: panel buffer (stride S); else (w, h, stride) of a slot surface sampled into PW x PH
BLIT = '0xa0000000 10183680'
REF = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fbref')
GRID = [(y, x) for y in range(200, 1600, 40) for x in range(40, 1040, 40)]


def feat_png(path, step=3):
    b = open(path, 'rb').read()
    w, h = struct.unpack('>II', b[16:24])
    i, idat = 8, b''
    while i < len(b):
        n, t = struct.unpack('>I4s', b[i:i + 8])
        if t == b'IDAT':
            idat += b[i + 8:i + 8 + n]
        i += 12 + n
    raw = zlib.decompress(idat)
    st = 1 + 3 * w	# filter type 0 rows (as png() writes them)
    px = lambda y, x: raw[y * st + 1 + 3 * x:y * st + 4 + 3 * x]
    return [sum(px(y // step, x // step)) // 3 for y, x in GRID]


def off(y, x):
    """byte offset of panel pixel (y, x) in the dump"""
    if SRC is None:
        return y * S + 4 * x
    w, h, st = SRC
    return min(y * h // PH, h - 1) * st + 4 * min(x * w // PW, w - 1)


def feat(d):
    return [(d[off(y, x)] + d[off(y, x) + 1] + d[off(y, x) + 2]) // 3 for y, x in GRID]


def png(d, dst, step):
    rows = []
    for y in range(0, PH, step):
        row = bytearray(b'\0')
        for x in range(0, PW, step):
            o = off(y, x)
            row += bytes((d[o + 2], d[o + 1], d[o]))
        rows.append(bytes(row))
    w = len(range(0, PW, step))

    def chunk(t, x):
        return struct.pack('>I', len(x)) + t + x + struct.pack('>I', zlib.crc32(t + x) & 0xffffffff)
    open(dst, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, len(rows), 8, 2, 0, 0, 0))
                          + chunk(b'IDAT', zlib.compress(b''.join(rows), 6)) + chunk(b'IEND', b''))


def where(regs, monklog=None):
    """the buffer the MDP scans out, from a 64-byte dump of VIG0's registers (/dev/pmem 0x0ae05000: +0x14 SRC0_ADDR,
    +0x24 YSTRIDE0) -- exact and independent of the kernel log (see the docstring)"""
    r = open(regs, 'rb').read()
    if len(r) < 0x28:
        return 'blit %s - (no regs)' % BLIT
    pa, stride = struct.unpack_from('<I', r, 0x14)[0], struct.unpack_from('<I', r, 0x24)[0] & 0xffff
    if pa == 0xa0000000 or pa == 0xa0a00000 or not stride:
        return 'blit 0x%x %d -' % (pa if pa else 0xa0000000, H * S)
    w, h, slot = 1125, 2436, '?'
    if monklog and os.path.exists(monklog):
        pat = re.compile(r'SWEET SURF: scanout slot (\d+) \([^)]*PA 0x%x\) for a (\d+)x(\d+) surface, (\d+)-byte rows' % pa)
        with open(monklog, 'rb') as f:
            for line in f:
                if b'SURF: scanout slot' in line:
                    m = pat.search(line.decode('latin-1'))
                    if m:
                        slot, w, h = m[1], int(m[2]), int(m[3])
    return 'direct 0x%x %d %dx%d:%d slot%s' % (pa, stride * h, w, h, stride, slot)


def main():
    global SRC
    if sys.argv[1] == '--where':
        print(where(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None))
        return
    if sys.argv[1] == '--mkref':
        src = sys.argv[3]
        if src.endswith('.png'):
            f = feat_png(src)
        else:
            d = open(src, 'rb').read()
            if len(d) >= 4608 * 2436:
                SRC = (1125, 2436, 4608)
            f = feat(d)
        os.makedirs(REF, exist_ok=True)
        json.dump(f, open(os.path.join(REF, sys.argv[2] + '.feat'), 'w'))
        return
    d = open(sys.argv[1], 'rb').read()
    g = re.fullmatch(r'(\d+)x(\d+):(\d+)', sys.argv[4]) if len(sys.argv) > 4 else None
    if g:
        SRC = (int(g[1]), int(g[2]), int(g[3]))
    elif len(d) >= 4608 * 2436:
        SRC = (1125, 2436, 4608)
    if len(d) < (SRC[1] * SRC[2] if SRC else H * S):
        print('short'); return
    png(d, sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 3)
    f = feat(d)
    lum = sum(f) / len(f)
    best, bd = None, 1e9
    for n in sorted(os.listdir(REF)) if os.path.isdir(REF) else []:
        if n.endswith('.feat'):
            r = json.load(open(os.path.join(REF, n)))
            dd = sum(abs(a - b) for a, b in zip(f, r)) / len(f)
            if dd < bd:
                best, bd = n[:-5], dd
    cls = best if best and bd <= 15 else ('dark' if lum < 25 else 'other')
    print('%s:%.0f:%.0f' % (cls, bd if best else -1, lum))


if __name__ == '__main__':
    main()
