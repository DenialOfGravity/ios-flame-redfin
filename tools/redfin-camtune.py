#!/usr/bin/env python3
"""Make a camera's colour tuning for the phone's camera plug-in (phone/audio/camera_isp.c, isp_load_tuning(): the
"RWCISP02" file /private/var/local/fw/camera-<sensor>.isp) out of the sensor's tuning file of the Pixel 5's camera
stack (/vendor/lib64/camera/com.qti.tuned.<vendor>_<sensor>.bin, pulled read-only by the phone agent's
twrp-pull-camera). The tuning files and what this makes of them are the vendor's: they stay out of git (recon/,
the phone).

  tools/redfin-camtune.py TUNED.bin -o camera-imx363.isp       make it
  tools/redfin-camtune.py TUNED.bin --dump                       what was found, and where (check this first)
  tools/redfin-camtune.py TUNED.bin --json found.json            what was found, as JSON to review or correct ...
  tools/redfin-camtune.py --from-json found.json -o OUT.isp      ... and the file made from the corrected JSON

What is taken (Qualcomm Chromatix 7 / CamX, IPE "cc13" and BPS "lsc34" modules, the AWB reference points):
  - colour matrices: 3x3 (c_tab), rows summing to about 1, each after its colour-temperature trigger (start, end
    in kelvin), the matrices of one lux-index trigger (start, end) together
  - lens shading: four 17x13 grids of gains (r, gr, gb, b; lsc34's mesh), with the same triggers
  - the AWB's reference lights: (R/G, B/G) of a grey under each, with their colour temperature where the records
    have one (else estimated from R/G between 7500 K and 2300 K)

HOW (VERIFY ON THE REAL FILES -- written without one): the file is taken to be the same container as the sensor
module files (tools/redfin-camtab.py: "QTI Chromatix Header", the symbol table's offset and size at 0xa8, the
data's at 0xc0, symbols { u64 id, char name[32], u64 kind, u64 parent, u64 offset, u64 size }); anything else is
read as plain data. The values are looked for by their shape, not by a parser of the file's types (which this has
not got): every encoding is tried -- 32-bit floats, 64-bit doubles, 32-bit floats in 64-bit slots (the module
files' u64 slots) -- and the one that finds most is taken. Where the symbol table has names, the finds are said
with the symbol they are in (--dump) and kept to symbols named like the module (cc, lsc, awb) when there are any.
Things to check on a real file: that --dump's matrices are the cc13 ones (not the ccm of another module), the
matrix's order (Qualcomm's c_tab may be in G, B, R order on some targets: --ccm-order), the triggers' pairing
(lux index ranges are 0..~500, higher darker; CCT ranges ascending), the reference lights' count (7-8) and order.

OUT ("RWCISP02", little-endian; camera_isp.c reads it):
  magic[8]
  colour matrices: u32 lights; lights x { f32 lux_from, f32 lux_to, u32 ccts; ccts x { f32 cct_from, f32 cct_to,
                   f32 m[9] (rows) } }
  lens shading:    the same, each with f32 grids[4][13][17] (R, Gr, Gb, B) in place of m
  u32 refs; refs x { f32 r/g, f32 b/g, f32 cct } from the bluest light to the reddest (at most 16)
At most 6 lights of 6 temperatures each (camera_isp.h TUNE_LIGHTS, TUNE_CCTS).
"""
import argparse
import json
import math
import struct
import sys

LSC_W, LSC_H = 17, 13
GRID = LSC_W * LSC_H
MAX_LIGHTS, MAX_CCTS, MAX_REFS = 6, 6, 16


# ---- the container ---------------------------------------------------------------------------------------------

def load(path):
    """(data, symbols): symbols [(name, kind, parent, offset, size)] with offsets into data"""
    with open(path, 'rb') as fp:
        d = fp.read()
    if not d.startswith(b'QTI Chromatix Header') or len(d) < 0xd0:
        return d, []
    toff, tsz = struct.unpack_from('<QQ', d, 0xa8)
    doff, dsz = struct.unpack_from('<QQ', d, 0xc0)
    if toff + tsz > len(d) or doff + dsz > len(d):
        return d, []
    syms = []
    for o in range(toff, toff + tsz - 0x47, 0x48):
        sid, name, kind, parent, off, size = struct.unpack_from('<Q32sQQQQ', d, o)
        syms.append((name.split(b'\0')[0].decode('latin1'), kind, parent, off, size))
    return d[doff:doff + dsz], syms


ENCODINGS = {'f32': (4, '<f', 0), 'f64': (8, '<d', 0), 'f32lo': (8, '<f', 0)}


def values(data, encoding):
    """the data as numbers in an encoding; each with its byte offset (index * stride)"""
    stride, fmt, _ = ENCODINGS[encoding]
    n = len(data) // stride
    if encoding == 'f32':
        v = list(struct.unpack_from('<%df' % n, data, 0))
    elif encoding == 'f64':
        v = list(struct.unpack_from('<%dd' % n, data, 0))
    else:
        v = list(struct.unpack_from('<%df' % (2 * n), data, 0))[0::2]
    return [x if math.isfinite(x) else float('nan') for x in v], stride


# ---- the shapes ------------------------------------------------------------------------------------------------

def is_ccm(v, i):
    d0, d1, d2 = v[i], v[i + 4], v[i + 8]
    if not (0.5 <= d0 <= 4 and 0.5 <= d1 <= 4 and 0.5 <= d2 <= 4):
        return False
    m = v[i:i + 9]
    if any(not (-3 <= x <= 4) for x in m):
        return False
    for r in range(3):
        if not 0.9 <= m[3 * r] + m[3 * r + 1] + m[3 * r + 2] <= 1.1:
            return False
    # (not three equal rows, not a run of a constant)
    return len(set(round(x, 4) for x in m)) >= 3


def whole(x):
    return abs(x - round(x)) < 1e-3


def pair_before(v, i, lo, hi, reach, strict=False):
    """
    the nearest (a, b) with lo <= a <= b <= hi in v[i - reach .. i - 1], both whole numbers (a trigger's ends are:
    tables' values are not): (a, b, index of a) or None
    """
    for j in range(i - 2, max(i - reach, 0) - 1, -1):
        a, b = v[j], v[j + 1]
        if lo <= a <= hi and lo <= b <= hi and (a < b if strict else a <= b) and whole(a) and whole(b):
            return a, b, j
    return None


def triggers(v, i):
    """
    the colour-temperature and lux-index triggers before a table at i: ((cct_from, cct_to) | None, (lux) | None).
    Chromatix's AEC trigger is { hint, lux index (start, end), gain (start, end) }: of two pairs right one after the
    other before the CCT trigger, the first is the lux index's (VERIFY on a real file with --dump).
    """
    cct = pair_before(v, i, 1000, 15000, 6)
    near = pair_before(v, cct[2] if cct else i, 0, 1000, 12, strict=True)
    lux = near
    if near is not None:
        j = near[2] - 2
        if j >= 0 and 0 <= v[j] < v[j + 1] <= 1000 and v[j + 1] > 1 and whole(v[j]) and whole(v[j + 1]):
            lux = (v[j], v[j + 1], j)
    return (cct[:2] if cct else None), (lux[:2] if lux else None)


def is_grid(v, i):
    g = v[i:i + GRID]
    if len(g) < GRID or not (0.85 <= g[0] <= 12):
        return False
    centre = g[6 * LSC_W + 8]
    if not (0.85 <= centre <= 2.0):
        return False
    if any(not (0.85 <= x <= 12) for x in g):
        return False
    corners = (g[0], g[LSC_W - 1], g[GRID - LSC_W], g[GRID - 1])
    if min(corners) < centre * 0.98:
        return False                    # (lens shading raises the corners)
    for y in range(LSC_H):
        row = g[y * LSC_W:(y + 1) * LSC_W]
        if any(abs(row[x + 1] - row[x]) > 0.35 * max(row[x], row[x + 1]) for x in range(LSC_W - 1)):
            return False
    return len(set(round(x, 3) for x in g)) > 10


def find_ccms(v, keep=None):
    out = []
    for i in range(0, len(v) - 9):
        if keep is not None and not keep(i):
            continue
        if is_ccm(v, i):
            cct, lux = triggers(v, i)
            out.append({'at': i, 'm': v[i:i + 9], 'cct': cct, 'lux': lux})
    return out


def find_lscs(v, keep=None):
    grids, i = [], 0
    while i < len(v) - GRID:
        if (keep is None or keep(i)) and is_grid(v, i):
            grids.append(i)
            i += GRID
        else:
            i += 1
    out, k = [], 0
    while k + 3 < len(grids):
        four = grids[k:k + 4]
        if all(four[j + 1] - four[j] <= GRID + 64 for j in range(3)):
            cct, lux = triggers(v, four[0])
            out.append({'at': four[0], 'grids': [v[g:g + GRID] for g in four], 'cct': cct, 'lux': lux})
            k += 4
        else:
            k += 1
    return out


def find_refs(v, keep=None):
    """the longest run of records (stride 2..8 values) of (R/G, B/G) that moves from blue light to red, R/G up and B/G down"""
    best = None
    n = len(v)
    for stride in range(2, 9):
        i = 0
        while i < n - stride * 5:
            if keep is not None and not keep(i):
                i += 1
                continue
            recs, j = [], i
            while j + 1 < n and 0.15 < v[j] < 2.5 and 0.15 < v[j + 1] < 2.5 and len(recs) < MAX_REFS:
                if recs and not (v[j] > recs[-1][0] * 1.01 and v[j + 1] < recs[-1][1] * 0.99):
                    break
                recs.append((v[j], v[j + 1], j))
                j += stride
            if len(recs) >= 5 and recs[-1][0] / recs[0][0] >= 1.5 and recs[0][1] / recs[-1][1] >= 1.5:
                # a colour temperature in the records: a field that falls from 15000..1500 as R/G rises
                cct_field = None
                for k in range(2, stride):
                    t = [v[r[2] + k] for r in recs if r[2] + k < n]
                    if len(t) == len(recs) and all(1500 <= x <= 15000 for x in t) and all(t[q] > t[q + 1] for q in range(len(t) - 1)):
                        cct_field = k
                        break
                score = len(recs) + (10 if cct_field is not None else 0)
                if best is None or score > best[0]:
                    best = (score, stride, recs, cct_field)
                i = j
            else:
                i += 1
    if best is None:
        return []
    _, stride, recs, cct_field = best
    rg0, rg1 = math.log(recs[0][0]), math.log(recs[-1][0])
    out = []
    for rg, bg, at in recs:
        if cct_field is not None:
            cct, estimated = v[at + cct_field], False
        else:
            t = (math.log(rg) - rg0) / (rg1 - rg0) if rg1 != rg0 else 0
            cct, estimated = 1 / (1 / 7500 + t * (1 / 2300 - 1 / 7500)), True
        out.append({'at': at, 'rg': rg, 'bg': bg, 'cct': cct, 'estimated': estimated})
    return out


# ---- what was found, into lights ---------------------------------------------------------------------------------

def into_lights(found, key):
    """tables -> [{lux: [from, to], ccts: [{cct: [from, to], key: value}]}] (ascending; at most 6 x 6)"""
    lights, current = [], None
    for t in found:
        if current is None or (t['lux'] is not None and list(t['lux']) != current['lux']):
            current = {'lux': list(t['lux']) if t['lux'] is not None else None, 'ccts': []}
            lights.append(current)
        current['ccts'].append(t)
    out = []
    for n, light in enumerate(lights):
        lux = light['lux'] or [n * 1000.0 / len(lights), (n + 1) * 1000.0 / len(lights)]
        entries, seen = [], set()
        for k, t in enumerate(light['ccts']):
            cct = list(t['cct']) if t['cct'] is not None else None
            if cct is not None and tuple(cct) in seen:
                continue
            if cct is not None:
                seen.add(tuple(cct))
            entries.append({'cct': cct, key: t[key]})
        # (no trigger found: spread over 2000..8000 K in their order)
        for k, e in enumerate(entries):
            if e['cct'] is None:
                step = 6000.0 / len(entries)
                e['cct'] = [2000 + k * step, 2000 + (k + 1) * step - 1]
        entries.sort(key=lambda e: e['cct'][0])
        if len(entries) > MAX_CCTS:
            entries = [entries[round(q * (len(entries) - 1) / (MAX_CCTS - 1))] for q in range(MAX_CCTS)]
        out.append({'lux': lux, 'ccts': entries})
    out.sort(key=lambda light: light['lux'][0])
    if len(out) > MAX_LIGHTS:
        out = [out[round(q * (len(out) - 1) / (MAX_LIGHTS - 1))] for q in range(MAX_LIGHTS)]
    return out


def reorder_ccm(m, order, transpose):
    if transpose:
        m = [m[3 * c + r] for r in range(3) for c in range(3)]
    if order == 'rgb':
        return m
    # the matrix's rows and columns are in `order' (e.g. gbr): to R, G, B
    idx = [order.index(c) for c in 'rgb']
    return [m[3 * idx[r] + idx[c]] for r in range(3) for c in range(3)]


def extract(data, syms, encoding='auto', say=print):
    tries = [encoding] if encoding != 'auto' else list(ENCODINGS)
    best = None
    for enc in tries:
        v, stride = values(data, enc)

        def in_named(pattern_words):
            spans = [(off // stride, (off + size) // stride) for name, _, _, off, size in syms
                     if any(w in name.lower() for w in pattern_words) and size > 0]
            if not spans:
                return None
            return lambda i: any(a <= i < b for a, b in spans)
        ccms = find_ccms(v, in_named(['cc1', 'ccm', 'color_corr', 'colorcorr']))
        if not ccms:
            ccms = find_ccms(v)
        lscs = find_lscs(v, in_named(['lsc', 'rolloff', 'shading']))
        if not lscs:
            lscs = find_lscs(v)
        # (where some tables have their triggers, the ones without are taken for chance shapes in other data)
        ccms = [t for t in ccms if t['cct'] is not None] or ccms
        lscs = [t for t in lscs if t['cct'] is not None] or lscs
        refs = find_refs(v, in_named(['awb']))
        if not refs:
            refs = find_refs(v)
        score = len(ccms) + 4 * len(lscs) + len(refs)
        say('encoding %-6s: %d colour matrices, %d lens shading tables, %d reference lights' % (enc, len(ccms), len(lscs), len(refs)))
        if best is None or score > best[0]:
            best = (score, enc, stride, ccms, lscs, refs)
    _, enc, stride, ccms, lscs, refs = best
    return {'encoding': enc, 'stride': stride, 'ccms': ccms, 'lscs': lscs, 'refs': refs}


def symbol_at(syms, offset):
    hit = [s for s in syms if s[3] <= offset < s[3] + s[4]]
    return min(hit, key=lambda s: s[4])[0] if hit else '-'


def dump(found, syms):
    stride = found['stride']
    print('taken: %s' % found['encoding'])
    for t in found['ccms']:
        print('colour matrix at 0x%x (%s): lux %s cct %s' % (t['at'] * stride, symbol_at(syms, t['at'] * stride), t['lux'], t['cct']))
        for r in range(3):
            print('    %8.4f %8.4f %8.4f' % tuple(t['m'][3 * r:3 * r + 3]))
    for t in found['lscs']:
        g = t['grids']
        print('lens shading at 0x%x (%s): lux %s cct %s; centre %s corners %s' % (
            t['at'] * stride, symbol_at(syms, t['at'] * stride), t['lux'], t['cct'],
            ' '.join('%.2f' % x[6 * LSC_W + 8] for x in g), ' '.join('%.2f' % x[0] for x in g)))
    for r in found['refs']:
        print('reference light at 0x%x (%s): R/G %.3f B/G %.3f, %.0f K%s' % (r['at'] * stride, symbol_at(syms, r['at'] * stride),
              r['rg'], r['bg'], r['cct'], ' (estimated)' if r['estimated'] else ''))
    if syms:
        print('symbols: %d (first 40):' % len(syms))
        for s in syms[:40]:
            print('    %-32s kind %d parent %d at 0x%x, %d bytes' % s)


def tuning_from(found, ccm_order='rgb', ccm_transpose=False):
    """the JSON-able tuning: {ccm: lights, lsc: lights, refs: [[rg, bg, cct]]}"""
    ccm = into_lights(found['ccms'], 'm')
    for light in ccm:
        for e in light['ccts']:
            e['m'] = reorder_ccm(e['m'], ccm_order, ccm_transpose)
    lsc = into_lights(found['lscs'], 'grids')
    refs = sorted(([r['rg'], r['bg'], r['cct']] for r in found['refs']), key=lambda r: -r[2])[:MAX_REFS]
    return {'ccm': ccm, 'lsc': lsc, 'refs': refs}


def write_isp(tuning, path):
    """camera_isp.c's RWCISP02; an identity matrix and flat shading where there are none"""
    ccm = tuning['ccm'] or [{'lux': [0, 1000], 'ccts': [{'cct': [0, 20000], 'm': [1, 0, 0, 0, 1, 0, 0, 0, 1]}]}]
    lsc = tuning['lsc'] or [{'lux': [0, 1000], 'ccts': [{'cct': [0, 20000], 'grids': [[1.0] * GRID] * 4}]}]
    out = bytearray(b'RWCISP02')
    for lights, key, floats in ((ccm, 'm', 9), (lsc, 'grids', 4 * GRID)):
        out += struct.pack('<I', len(lights))
        for light in lights:
            out += struct.pack('<ffI', light['lux'][0], light['lux'][1], len(light['ccts']))
            for e in light['ccts']:
                v = e[key] if key == 'm' else [x for g in e[key] for x in g]
                assert len(v) == floats
                out += struct.pack('<ff', e['cct'][0], e['cct'][1]) + struct.pack('<%df' % floats, *v)
    out += struct.pack('<I', len(tuning['refs']))
    for r in tuning['refs']:
        out += struct.pack('<fff', *r)
    with open(path, 'wb') as fp:
        fp.write(bytes(out))
    return len(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tuned', nargs='?', help='com.qti.tuned.*.bin')
    ap.add_argument('-o', '--out', help='camera-<sensor>.isp to write')
    ap.add_argument('--dump', action='store_true', help='say what was found and where')
    ap.add_argument('--json', help='write what was found (after --ccm-*) as JSON')
    ap.add_argument('--from-json', help='make the .isp from this JSON instead of a tuning file')
    ap.add_argument('--encoding', default='auto', choices=['auto'] + list(ENCODINGS))
    ap.add_argument('--ccm-order', default='rgb', help="the order of the matrix's colours in the file (e.g. gbr)")
    ap.add_argument('--ccm-transpose', action='store_true', help='the matrix is stored by columns')
    ap.add_argument('--refs', help='reference lights instead of the found ones: "rg,bg,cct;rg,bg,cct;..."')
    a = ap.parse_args(argv)
    if a.from_json:
        with open(a.from_json) as fp:
            tuning = json.load(fp)
    elif a.tuned:
        data, syms = load(a.tuned)
        found = extract(data, syms, a.encoding)
        if a.dump:
            dump(found, syms)
        tuning = tuning_from(found, a.ccm_order, a.ccm_transpose)
    else:
        ap.error('a tuning file or --from-json')
    if a.refs:
        tuning['refs'] = sorted(([float(x) for x in r.split(',')] for r in a.refs.split(';') if r), key=lambda r: -r[2])
    if a.json:
        with open(a.json, 'w') as fp:
            json.dump(tuning, fp, indent=1)
    print('colour matrices: %s; lens shading: %s; reference lights: %d' % (
        ', '.join('lux %g-%g x %d' % (l['lux'][0], l['lux'][1], len(l['ccts'])) for l in tuning['ccm']) or 'none (identity)',
        ', '.join('lux %g-%g x %d' % (l['lux'][0], l['lux'][1], len(l['ccts'])) for l in tuning['lsc']) or 'none (flat)',
        len(tuning['refs'])))
    if a.out:
        print('%s: %d bytes' % (a.out, write_isp(tuning, a.out)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
