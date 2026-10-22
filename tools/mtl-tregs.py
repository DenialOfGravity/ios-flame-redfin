import json, sys
def regs_of(path):
    d = json.load(open(path))
    out = {}
    for g in d['groups']:
        dw, i = g['dw'], 0
        while i < len(dw):
            h = dw[i]
            if h >> 28 == 4:
                n, reg = h & 0x7f, (h >> 8) & 0x3ffff
                for k in range(n):
                    out[reg + k] = dw[i + 1 + k]
                i += 1 + n
            elif h >> 28 == 7:
                n, op = h & 0x3fff, (h >> 16) & 0x7f
                if op in (0x5c, 0x5d):      # CP_CONTEXT_REG_BUNCH: reg, value pairs
                    for k in range(0, n, 2):
                        out[dw[i + 1 + k]] = dw[i + 2 + k]
                i += 1 + n
            else:
                i += 1
    return out
names = {0x8820: 'RB_MRT0_CONTROL', 0x8821: 'RB_MRT0_BLEND_CONTROL', 0x8865: 'RB_BLEND_CNTL', 0x8864: 'RB_BLEND_RED?', 0x9a20: '?', 0xa9b3: '?', 0x8811: 'RB_RENDER_CNTL?'}
for h in sys.argv[1:]:
    r = regs_of('phone/metal/pipelines/%s.json' % h)
    print(h, ' '.join('%s=%x' % (names.get(k, hex(k)), v) for k, v in sorted(r.items()) if k in (0x8820, 0x8821, 0x8865)))
