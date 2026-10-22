#!/usr/bin/env python3
"""metallib.py: list a .metallib's functions or extract one function's AIR bitcode.
  metallib.py LIB                 list: name, type, bitcode size
  metallib.py LIB NAME OUT.bc     extract (then: /opt/homebrew/opt/llvm/bin/llvm-dis OUT.bc)
Format (MTLB): header with (offset, size) pairs for the function list, public and private metadata and
the bitcode; each function list entry is tags (4 chars + u16 length) up to ENDT: NAME, TYPE, OFFT
(public md, private md, bitcode offsets, relative to their sections), MDSZ (bitcode size), ...
"""
import struct, sys

def parse(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'MTLB', 'not a metallib'
    fl_off, fl_size, pub_off, pub_size, priv_off, priv_size, bc_off, bc_size = struct.unpack_from('<8Q', d, 0x18)
    n, = struct.unpack_from('<I', d, fl_off)
    o = fl_off + 4
    funcs = []
    for _ in range(n):
        size, = struct.unpack_from('<I', d, o)
        p, end, f = o + 4, o + size, {}
        while p < end:
            tag = d[p:p + 4]
            if tag == b'ENDT':
                break
            ln, = struct.unpack_from('<H', d, p + 4)
            val = d[p + 6:p + 6 + ln]
            if tag == b'NAME':
                f['name'] = val.rstrip(b'\0').decode()
            elif tag == b'TYPE':
                f['type'] = val[0]
            elif tag == b'OFFT':
                f['pub'], f['priv'], f['bc'] = struct.unpack_from('<3Q', val)
            elif tag == b'MDSZ':
                f['bcsize'], = struct.unpack_from('<Q', val)
            p += 6 + ln
        f['bc_abs'] = bc_off + f.get('bc', 0)
        funcs.append(f)
        o = end
    return d, funcs

if __name__ == '__main__':
    d, funcs = parse(sys.argv[1])
    if len(sys.argv) == 2:
        types = {0: 'vertex', 1: 'fragment', 2: 'kernel'}
        for f in funcs:
            print('%-40s %-8s %7d' % (f['name'], types.get(f.get('type'), f.get('type')), f.get('bcsize', 0)))
    else:
        f = next(f for f in funcs if f['name'] == sys.argv[2])
        open(sys.argv[3], 'wb').write(d[f['bc_abs']:f['bc_abs'] + f['bcsize']])
        print('%s: %d bytes' % (f['name'], f['bcsize']))
