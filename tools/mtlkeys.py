#!/usr/bin/env python3
"""mtlkeys.py: the render pipelines a SweetMetal log (/var/local/mtl.log) shows, one JSON object each.
  mtlkeys.py LOG... > keys.json
A key is what SweetMetal logs per new pipeline: "VS + FS -> fmt F blend B | vertex fcs | fragment fcs | vd ...";
'raw' is that string exactly (SweetMetal looks templates up as pipelines/<sha1(raw)[:12]>.json).
"""
import json, re, sys

def parse(lines):
    # In log order: logs of several boots are concatenated and pids repeat, so a
    # "pipeline N" line belongs to the latest key line of that pid and number.
    entries, cur = [], {}
    for l in lines:
        m = re.match(r'MTL\[(\d+) [^\]]*\]: pipeline (\d+) lib: (\S+) \| (\S+)$', l)
        if m:
            i = cur.get((m.group(1), m.group(2)))
            if i is not None:
                entries[i][1] = (m.group(3), m.group(4))
            continue
        m = re.match(r'MTL\[(\d+) ([^\]]*)\]: pipeline (\d+)(\+?): (.*)$', l)
        if m:
            k = (m.group(1), m.group(3))
            if m.group(4) and k in cur:
                entries[cur[k]][0] += m.group(5)
            else:
                cur[k] = len(entries)
                entries.append([m.group(5), None])
    out = {}
    for s, lib in entries:
        m = re.match(r'(\S+) \+ (\S+) -> fmt (\d+) blend (\d)(?: wm (\d+))?(?: bf ([\d,]+))?(.*)$', s)
        if not m:
            continue
        parts = [p.strip() for p in m.group(7).split('|')]
        kv = lambda p: dict(x.split('=', 1) for x in p.split()) if p else {}
        k = {'vs': m.group(1), 'fs': m.group(2), 'fmt': int(m.group(3)), 'blend': int(m.group(4)),
             'vfc': {}, 'ffc': {}, 'vd': '', 'att': {}, 'raw': s, 'wm': int(m.group(5)) if m.group(5) else 15,
             'bf': [int(x) for x in m.group(6).split(',')] if m.group(6) else None}
        vl, fl = lib or ('?', '?')
        if vl != '?':
            k['vlib'] = vl
        if fl != '?':
            k['flib'] = fl
        for p in parts:
            if p in ('vfc', 'ffc'):
                pass                # no function constants
            elif p.startswith('vfc '):
                k['vfc'] = kv(p[4:])
            elif p.startswith('ffc '):
                k['ffc'] = kv(p[4:])
            elif p.startswith('vd '):
                k['vd'] = p[3:]
            elif re.match(r'att\d+ fmt', p):
                a = re.match(r'att(\d+) fmt (\d+) blend (\d)(?: wm (\d+))?(?: bf ([\d,]+))?', p)
                k['att'][a.group(1)] = [int(a.group(2)), int(a.group(3)), int(a.group(4)) if a.group(4) else 15,
                                        [int(x) for x in a.group(5).split(',')] if a.group(5) else None]
            elif p:
                k['old'] = True      # an older log format (fcs without vfc/ffc markers)
        if not k.get('old'):
            key = json.dumps({x: y for x, y in k.items() if x not in ('vlib', 'flib')}, sort_keys=True)
            if key not in out or 'flib' in k:
                out[key] = k
    return list(out.values())

if __name__ == '__main__':
    lines = []
    for f in sys.argv[1:]:
        lines += open(f, errors='replace').read().split('\n')
    json.dump(parse(lines), sys.stdout, indent=1)
