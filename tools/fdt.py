#!/usr/bin/env python3
"""Read a flattened device tree (the live FDT from the phone).

  fdt.py DTB find PATTERN        nodes whose path matches the regex
  fdt.py DTB node PATH [-r]      properties of one node (-r: with children)
  fdt.py DTB phandle N           path of the node with that phandle
  fdt.py DTB compat REGEX        nodes whose compatible matches

dtc 1.8 asserts on some vendor properties of this tree, so this parses the
blob directly. Values print as strings, cell lists or hex bytes.
"""
import re, struct, sys


class Node:
    def __init__(self, name, parent=None):
        self.name, self.parent = name, parent
        self.props, self.children = {}, []

    @property
    def path(self):
        if self.parent is None:
            return '/'
        p = self.parent.path
        return (p if p != '/' else '') + '/' + self.name

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()

    def u32s(self, prop):
        v = self.props.get(prop)
        return None if v is None else list(struct.unpack('>%dI' % (len(v) // 4), v[:len(v) // 4 * 4]))

    def str(self, prop):
        v = self.props.get(prop)
        return None if v is None else v.rstrip(b'\0').split(b'\0')[0].decode(errors='replace')

    def strs(self, prop):
        v = self.props.get(prop)
        return [] if v is None else [s.decode(errors='replace') for s in v.rstrip(b'\0').split(b'\0')]

    def child(self, name):
        for c in self.children:
            if c.name == name or c.name.split('@')[0] == name:
                return c
        return None

    def reg(self):
        """reg as (addr, size) pairs using the parent's #address-cells/#size-cells."""
        cells = self.u32s('reg')
        if cells is None:
            return []
        p = self.parent
        ac = p.u32s('#address-cells')[0] if p and '#address-cells' in p.props else 2
        sc = p.u32s('#size-cells')[0] if p and '#size-cells' in p.props else 1
        out = []
        for i in range(0, len(cells) - ac - sc + 1, ac + sc):
            a = 0
            for c in cells[i:i + ac]:
                a = a << 32 | c
            s = 0
            for c in cells[i + ac:i + ac + sc]:
                s = s << 32 | c
            out.append((a, s))
        return out


def parse(blob):
    magic, total, off_struct, off_strings = struct.unpack_from('>4I', blob, 0)
    assert magic == 0xd00dfeed, 'not an FDT'
    p = off_struct
    root = cur = None
    while True:
        tok, = struct.unpack_from('>I', blob, p)
        p += 4
        if tok == 1:
            end = blob.index(b'\0', p)
            name = blob[p:end].decode()
            p = (end + 4) & ~3
            n = Node(name or '/', cur)
            if cur is None:
                root = n
            else:
                cur.children.append(n)
            cur = n
        elif tok == 2:
            cur = cur.parent
        elif tok == 3:
            ln, nameoff = struct.unpack_from('>II', blob, p)
            p += 8
            pname = blob[off_strings + nameoff:blob.index(b'\0', off_strings + nameoff)].decode()
            cur.props[pname] = bytes(blob[p:p + ln])
            p = (p + ln + 3) & ~3
        elif tok == 4:
            continue
        elif tok == 9:
            return root
        else:
            raise ValueError(f'bad token {tok:#x} at {p - 4:#x}')


def fmt(v):
    if not v:
        return '<empty>'
    if v[-1:] == b'\0' and all(32 <= c < 127 or c == 0 for c in v) and v[0] != 0:
        return ' | '.join(repr(s.decode()) for s in v.rstrip(b'\0').split(b'\0'))
    if len(v) % 4 == 0:
        cells = struct.unpack('>%dI' % (len(v) // 4), v)
        if len(cells) > 64:
            return '<' + ' '.join('%#x' % c for c in cells[:64]) + f' ...> ({len(cells)} cells)'
        return '<' + ' '.join('%#x' % c for c in cells) + '>'
    return v.hex()


def by_phandle(root):
    out = {}
    for n in root.walk():
        for k in ('phandle', 'linux,phandle'):
            if k in n.props:
                out[n.u32s(k)[0]] = n
    return out


def show(n, recurse=False, depth=0):
    ind = '  ' * depth
    print(f'{ind}{n.path} {{')
    for k, v in n.props.items():
        print(f'{ind}  {k} = {fmt(v)}')
    if recurse:
        for c in n.children:
            show(c, True, depth + 1)
    else:
        for c in n.children:
            print(f'{ind}  [{c.name}]')
    print(f'{ind}}}')


def lookup(root, path):
    n = root
    for part in [x for x in path.split('/') if x]:
        n = n.child(part)
        if n is None:
            raise SystemExit(f'no node {path}')
    return n


if __name__ == '__main__':
    root = parse(open(sys.argv[1], 'rb').read())
    cmd = sys.argv[2]
    if cmd == 'find':
        rx = re.compile(sys.argv[3])
        for n in root.walk():
            if rx.search(n.path):
                print(n.path)
    elif cmd == 'node':
        show(lookup(root, sys.argv[3]), '-r' in sys.argv)
    elif cmd == 'phandle':
        print(by_phandle(root)[int(sys.argv[3], 0)].path)
    elif cmd == 'compat':
        rx = re.compile(sys.argv[3])
        for n in root.walk():
            c = n.strs('compatible')
            if any(rx.search(x) for x in c):
                print(n.path, c, ['%#x/%#x' % r for r in n.reg()])
