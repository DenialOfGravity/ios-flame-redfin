#!/usr/bin/env python3
"""Make a device's status page out of its device.conf (the HakiOS vayu port's convention), so the status is
said in one place.

  python3 -I tools/docs-gen.py DEVICE [--check]

Reads devices/DEVICE/device.conf, writes docs/devices/DEVICE.md (written aside and renamed, so a failure leaves
the old page). --check writes nothing and exits 1 when the committed page differs from what would be made.

device.conf: `#` starts a comment; `device NAME` opens the block; then `KEY VALUE` lines (title, vendor, soc,
...: shown in the facts table in their order) and `status SUBSYSTEM works|partial|missing NOTE`.
"""
import os
import sys

STATES = ('works', 'partial', 'missing')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse(path):
    name, facts, status = None, [], []
    for no, raw in enumerate(open(path, encoding='utf-8'), 1):
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        key, rest = parts[0], (parts[1].strip() if len(parts) > 1 else '')
        if key == 'device':
            if name is not None:
                sys.exit(f'{path}:{no}: a second device line')
            name = rest
        elif name is None:
            sys.exit(f'{path}:{no}: "{key}" before the device line')
        elif key == 'status':
            f = rest.split(None, 2)
            if len(f) < 2 or f[1] not in STATES:
                sys.exit(f'{path}:{no}: status SUBSYSTEM {"|".join(STATES)} NOTE')
            if any(s[0] == f[0] for s in status):
                sys.exit(f'{path}:{no}: {f[0]} twice')
            status.append((f[0], f[1], f[2] if len(f) > 2 else ''))
        else:
            facts.append((key, rest))
    if name is None:
        sys.exit(f'{path}: no device line')
    return name, facts, status


def cell(s):
    return s.replace('|', '\\|')


def render(dev, name, facts, status):
    f = dict(facts)
    title = f.get('title', name)
    out = [f'# {title} ({name}): status', '',
           f'Made by `tools/docs-gen.py {dev}` from [devices/{dev}/device.conf](../../devices/{dev}/device.conf); '
           'edit that file, not this page.', '',
           '| | |', '|---|---|']
    out += [f'| {cell(k)} | {cell(v)} |' for k, v in facts]
    counts = {s: sum(1 for x in status if x[1] == s) for s in STATES}
    out += ['', '## Subsystems', '',
            ', '.join(f'{counts[s]} {s}' for s in STATES) + f' (of {len(status)}).', '',
            '| Subsystem | State | Notes |', '|---|---|---|']
    order = {s: i for i, s in enumerate(STATES)}
    for sub, st, note in sorted(status, key=lambda x: order[x[1]]):
        out.append(f'| {cell(sub)} | {st} | {cell(note)} |')
    return '\n'.join(out) + '\n'


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    if len(args) != 1:
        sys.exit(__doc__)
    dev = args[0]
    conf = os.path.join(ROOT, 'devices', dev, 'device.conf')
    page = os.path.join(ROOT, 'docs', 'devices', dev + '.md')
    text = render(dev, *parse(conf))
    if '--check' in argv:
        old = open(page, encoding='utf-8').read() if os.path.exists(page) else None
        print(f'docs-gen: {page}: ' + ('up to date' if old == text else 'STALE (run without --check)'))
        return 0 if old == text else 1
    os.makedirs(os.path.dirname(page), exist_ok=True)
    tmp = page + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(text)
    os.replace(tmp, page)
    print(f'docs-gen: wrote {os.path.relpath(page, ROOT)}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
