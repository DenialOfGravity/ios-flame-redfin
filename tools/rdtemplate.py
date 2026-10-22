#!/usr/bin/env python3
"""rdtemplate.py: a SweetMetal pipeline template from a turnip capture (work/mesa/draw/capture.sh).
  rdtemplate.py CAPTURE.rd OUT.json [--dump]
Finds the CP_SET_DRAW_STATE that precedes the (first) indexed draw and writes each state group's dwords,
with relocations: (dword index, target buffer iova, offset) for every lo/hi pair that points into a
captured buffer, so the phone can patch them (shader code is included: the program groups' SP_*_BASE).
"""
import gzip, json, struct, sys

RD_GPUADDR, RD_CMDSTREAM_ADDR, RD_BUFFER_CONTENTS = 3, 6, 12
CP_SET_DRAW_STATE, CP_INDIRECT_BUFFER, CP_DRAW_INDX_OFFSET = 0x43, 0x3f, 0x38

def load(path):
    d = gzip.open(path).read() if open(path, 'rb').read(2) == b'\x1f\x8b' else open(path, 'rb').read()
    bufs, streams, o, pending = {}, [], 0, None
    while o + 8 <= len(d):
        t, n = struct.unpack_from('<II', d, o)
        body = d[o + 8:o + 8 + n]
        o += 8 + n
        if t == RD_GPUADDR:
            lo, size = struct.unpack_from('<II', body)
            hi = struct.unpack_from('<I', body, 8)[0] if len(body) >= 12 else 0
            pending = (hi << 32 | lo, size)
        elif t == RD_BUFFER_CONTENTS and pending:
            bufs[pending[0]] = body
            pending = None
        elif t == RD_CMDSTREAM_ADDR:
            lo, sz = struct.unpack_from('<II', body)
            hi = struct.unpack_from('<I', body, 8)[0] if len(body) >= 12 else 0
            streams.append((hi << 32 | lo, sz))
    return bufs, streams

def find(bufs, va):
    for base, data in bufs.items():
        if base <= va < base + len(data):
            return base, va - base
    return None, None

def dwords(bufs, va, n):
    base, off = find(bufs, va)
    if base is None:
        raise ValueError('no buffer at %#x' % va)
    return list(struct.unpack_from('<%dI' % n, bufs[base], off))

def packets(dw):
    i = 0
    while i < len(dw):
        h = dw[i]
        if h >> 28 == 7:
            op, cnt = (h >> 16) & 0x7f, h & 0x3fff
            yield i, op, dw[i + 1:i + 1 + cnt]
            i += 1 + cnt
        elif h >> 28 == 4:
            cnt = h & 0x7f
            yield i, ('reg', (h >> 8) & 0x3ffff), dw[i + 1:i + 1 + cnt]
            i += 1 + cnt
        else:
            i += 1

def walk(bufs, va, n, out, depth=0):
    for _, op, body in packets(dwords(bufs, va, n)):
        out.append((op, body))
        if op == CP_INDIRECT_BUFFER and depth < 4:
            walk(bufs, body[0] | body[1] << 32, body[2] & 0xfffff, out, depth + 1)

def main():
    bufs, streams = load(sys.argv[1])
    seq = []
    for va, n in streams:
        walk(bufs, va, n, seq)
    if '--dump' in sys.argv:
        for op, body in seq:
            print(('%#x' % op) if isinstance(op, int) else 'reg %#x' % op[1], len(body))
    last_ds, draw = None, None
    for op, body in seq:
        if op == CP_SET_DRAW_STATE and len(body) >= 3 and body[0] & 0xffff:
            last_ds = body
        if op == CP_DRAW_INDX_OFFSET:
            draw = body
            break
    assert last_ds and draw, 'no draw'
    groups = []
    for g in range(0, len(last_ds), 3):
        hdr, lo, hi = last_ds[g:g + 3]
        cnt, gid = hdr & 0xffff, (hdr >> 24) & 0x1f
        flags = hdr & 0x00ff0000
        dw = dwords(bufs, lo | hi << 32, cnt) if cnt else []
        relocs = []
        for i in range(len(dw) - 1):
            v = dw[i] | dw[i + 1] << 32
            base, off = find(bufs, v) if v else (None, None)
            if base is not None and v > 0x10000:
                relocs.append({'dw': i, 'buf': '%#x' % base, 'off': off})
        groups.append({'id': gid, 'flags': flags, 'dwords': dw, 'relocs': relocs})
    # buffers the relocations point into (shader code, descriptor sets, ...), with their contents
    used = sorted({r['buf'] for g in groups for r in g['relocs']})
    tmpl = {'groups': groups, 'draw': draw,
            'buffers': {b: {'size': len(bufs[int(b, 16)]), 'data': bufs[int(b, 16)].hex()} for b in used}}
    json.dump(tmpl, open(sys.argv[2], 'w'))
    for g in groups:
        print('group %2d flags %#08x %3d dwords relocs %s' % (g['id'], g['flags'], len(g['dwords']),
              ' '.join('%d->%s+%#x' % (r['dw'], r['buf'], r['off']) for r in g['relocs'])))
    print('draw', ' '.join('%#x' % x for x in draw))
    for b in used:
        print('buffer %s: %d bytes' % (b, len(bufs[int(b, 16)])))

if __name__ == '__main__':
    main()

CP_CONTEXT_REG_BUNCH, CP_REG_WRITE, CP_SET_AMBLE, CP_COND_REG_EXEC = 0x5c, 0x6d, 0x55, 0x47

def reg_writes(bufs, streams, stop_at_draw=True):
    """Execution-order list of ('reg', offset, value) and ('pkt', opcode, body) up to the draw's state."""
    out = []
    def go(va, n, depth):
        dw = dwords(bufs, va, n)
        skip_until = -1
        for at, op, body in packets(dw):
            if at < skip_until:
                continue
            if op == CP_COND_REG_EXEC and len(body) >= 2:
                # RENDER_MODE (3): the next DWORDS run only in the modes whose bits are set; we render
                # in sysmem (bit 27). Other modes (predicates) count as taken.
                if body[0] >> 28 == 3 and not (body[0] >> 27) & 1:
                    skip_until = at + 1 + len(body) + (body[1] & 0xffffff)
                continue
            if isinstance(op, tuple):
                for k, v in enumerate(body):
                    out.append(('reg', op[1] + k, v))
            elif op == CP_CONTEXT_REG_BUNCH:
                for k in range(0, len(body) - 1, 2):
                    out.append(('reg', body[k], body[k + 1]))
            elif op == CP_REG_WRITE and len(body) >= 3:
                out.append(('reg', body[1], body[2]))
            elif op == CP_INDIRECT_BUFFER and depth < 4:
                go(body[0] | body[1] << 32, body[2] & 0xfffff, depth + 1)
            elif op == CP_SET_AMBLE and len(body) >= 3 and (body[0] | body[1]):
                # preamble IBs: run their contents too (the device's one-time setup)
                go(body[0] | body[1] << 32, body[2] & 0xfffff, depth + 1)
            elif op == CP_DRAW_INDX_OFFSET and stop_at_draw:
                out.append(('pkt', op, body))
                raise StopIteration
            else:
                out.append(('pkt', op, body))
    try:
        for va, n in streams:
            go(va, n, 0)
    except StopIteration:
        pass
    return out

# ---- export for the phone: commands with named patch points ----

def patch_name(reg):
    """Registers SweetMetal fills in per draw/pass (None: copied as captured)."""
    if 0xa010 <= reg < 0xa010 + 4 * 32:
        n, k = divmod(reg - 0xa010, 4)
        return {0: 'vb%d.lo' % n, 1: 'vb%d.hi' % n, 2: 'vb%d.size' % n}.get(k)
    for base, nm in ((0xab10, 'bindless'), (0xbb20, 'bindless')):
        if base <= reg < base + 2 * 8:
            n, k = divmod(reg - base, 2)
            return '%s%d.%s' % (nm, n, 'lo' if k == 0 else 'hi')
    named = {0x8010: 'vp.xoff', 0x8011: 'vp.xscale', 0x8012: 'vp.yoff', 0x8013: 'vp.yscale',
             0x80d0: 'vpsc.tl', 0x80d1: 'vpsc.br', 0x80b0: 'scsc.tl', 0x80b1: 'scsc.br',
             0x8822: 'rt.info', 0x8823: 'rt.pitch', 0x8824: 'rt.apitch', 0x8825: 'rt.lo', 0x8826: 'rt.hi',
             0x8903: 'rt.flag.lo', 0x8904: 'rt.flag.hi', 0xa996: 'rt.spfmt', 0x8102: 'rt.lrzfmt',
             0x80f1: 'window.br', 0x840b: 'a2d.br'}
    return named.get(reg)

def decode_regs(dw):
    """(dword index of the value, register) for every register write in a dword stream."""
    out = []
    for at, op, body in packets(dw):
        if isinstance(op, tuple):
            for k in range(len(body)):
                out.append((at + 1 + k, op[1] + k))
        elif op == CP_CONTEXT_REG_BUNCH:
            for k in range(0, len(body) - 1, 2):
                out.append((at + 2 + k, body[k]))
        elif op == CP_REG_WRITE and len(body) >= 3:
            out.append((at + 3, body[1]))
    return out

def shader_bytes(b):
    """The shader BO's contents up to the last non-zero 4K page (turnip's BO is 128 KB, mostly empty)."""
    end = len(b.rstrip(b'\0'))
    return b[:min(len(b), (end + 4095) & ~4095)].hex()

def export(path, out):
    bufs, streams = load(path)
    seq = []
    for va, n in streams:
        walk(bufs, va, n, seq)
    ds = None
    for op, body in seq:
        if op == CP_SET_DRAW_STATE and len(body) >= 3 and body[0] & 0xffff:
            ds = body
        if op == CP_DRAW_INDX_OFFSET:
            break
    # the shader code: what group 1's CP_LOAD_STATE6 loads from
    shader_base = None
    groups = []
    for g in range(0, len(ds), 3):
        hdr, lo, hi = ds[g:g + 3]
        cnt, gid = hdr & 0xffff, (hdr >> 24) & 0x1f
        dw = dwords(bufs, lo | hi << 32, cnt) if cnt else []
        patches = []
        for i, reg in decode_regs(dw):
            nm = patch_name(reg)
            if nm:
                patches.append([i, nm])
        for at, op, body in packets(dw):
            if op in (0x30, 0x32, 0x34) and len(body) >= 3 and (body[0] >> 16) & 3 == 2:   # SS6_INDIRECT
                va = body[1] | body[2] << 32
                base, off = find(bufs, va)
                if base is not None:
                    shader_base = shader_base or base
                    patches.append([at + 2, 'shader.lo+%d' % (va - shader_base)])
                    patches.append([at + 3, 'shader.hi+%d' % (va - shader_base)])
        groups.append({'id': gid, 'flags': hdr & 0x00ff0000, 'dw': dw, 'patch': patches})
    # SP_*_BASE registers (reg pairs, not adjacent in CONTEXT_REG_BUNCH): relocate by value
    SHADER_BASE_REGS = {0xa81c: 'vs', 0xa983: 'ps', 0xa834: 'hs', 0xa868: 'ds', 0xa89b: 'gs'}
    for gr in groups:
        regs = dict((reg, i) for i, reg in decode_regs(gr['dw']))
        for reg in SHADER_BASE_REGS:
            if reg in regs and reg + 1 in regs:
                va = gr['dw'][regs[reg]] | gr['dw'][regs[reg + 1]] << 32
                if shader_base and shader_base <= va < shader_base + len(bufs[shader_base]):
                    gr['patch'].append([regs[reg], 'shader.lo+%d' % (va - shader_base)])
                    gr['patch'].append([regs[reg + 1], 'shader.hi+%d' % (va - shader_base)])
    # prologue (up to the draw's state) and epilogue, as register writes and other packets
    items = reg_writes(bufs, streams, stop_at_draw=False)
    pro, epi, cur = [], [], None
    seen_draw = False
    for kind, a, b in items:
        if kind == 'pkt' and a == CP_SET_DRAW_STATE and b is ds:
            continue
        if kind == 'pkt' and a == CP_SET_DRAW_STATE and len(b) >= 3 and b[0] & 0xffff and not seen_draw:
            continue          # the draw's state: emitted per draw
        if kind == 'pkt' and a == CP_DRAW_INDX_OFFSET:
            seen_draw = True
            continue
        if kind == 'pkt' and a == CP_SET_AMBLE:
            continue
        lst = epi if seen_draw else pro
        if kind == 'reg':
            lst.append({'r': a, 'v': b, 'p': patch_name(a)})
        else:
            lst.append({'k': a, 'b': list(b)})
    # references to turnip's global buffer (border colours, CP_MEM_TO_REG sources): relocated with it
    gbase = min(bufs)
    gend = gbase + len(bufs[gbase])
    sys.path.insert(0, __import__('os').path.dirname(__file__))
    import pm4
    regname = {}
    for k, v in pm4.regs().items():
        regname.setdefault(v, k)
    for lst in (pro, epi):
        # every write of a BASE/ADDR pair, not only the last (the prologue sets some twice)
        last = {}
        for idx, x in enumerate(lst):
            if 'r' not in x:
                continue
            last[x['r']] = idx
            lo = last.get(x['r'] - 1)
            if lo is not None and any(w in regname.get(x['r'] - 1, '') for w in ('BASE', 'ADDR')):
                va = lst[lo]['v'] | x['v'] << 32
                if gbase <= va < gend:
                    lst[lo]['p'] = 'global.lo+%d' % (va - gbase)
                    x['p'] = 'global.hi+%d' % (va - gbase)
        for x in lst:
            if 'k' not in x:
                continue
            b = x['b']
            # address pairs in packet bodies: CP_MEM_TO_REG / CP_EVENT_WRITE / CP_MEM_WRITE / CP_REG_TO_MEM (dw1-2)
            if x['k'] in (0x42, 0x46, 0x3d, 0x3e) and len(b) >= 3:
                va = b[1] | b[2] << 32
                if gbase <= va < gend:
                    x['pb'] = [[1, 'global.lo+%d' % (va - gbase)], [2, 'global.hi+%d' % (va - gbase)]]
                    continue
            for j in range(len(b) - 1):
                va = b[j] | b[j + 1] << 32
                if any(lo <= va < lo + len(bufs[lo]) for lo in bufs):
                    print('warning: packet %#x dw %d holds capture VA %#x (not relocated)' % (x['k'], j, va),
                          file=sys.stderr)
    globals_ = {'%#x' % base: bufs[base].hex() for base in bufs if base == min(bufs)}   # turnip's global BO
    t = {'groups': groups, 'prologue': pro, 'epilogue': epi,
         'draw': [x for op, x in seq if op == CP_DRAW_INDX_OFFSET][0],
         'shader': {'base': '%#x' % shader_base, 'data': shader_bytes(bufs[shader_base])}, 'globals': globals_}
    json.dump(t, open(out, 'w'))
    return t

if __name__ == '__main__' and len(sys.argv) > 3 and sys.argv[3] == '--export':
    pass
