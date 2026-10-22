#!/usr/bin/env python3
"""PM4 command streams for the A640, assembled on the Mac (names from Mesa's register database).

  tools/pm4.py IN.txt OUT.bin       assemble; then tools/flame-files.py put OUT.bin /var/tmp/x.bin
                                    and tools/flame-ssh 'gpu submit /var/tmp/x.bin'
  tools/pm4.py --op NAME | --reg NAME   look up an opcode / register

Text format, one packet per line ('#' comments, numbers 0x.. or decimal):
  pkt7 CP_MEM_WRITE 0x10400000 0 0xcafef00d     type-7 packet, opcode by name or number
  pkt4 CP_SCRATCH[0] 0x12345678                 type-4 register write (count = values given)
  dw 0x1 0x2                                     raw dwords
  @name = 0x10400000                             symbol, usable as an argument; lo(@x) / hi(@x)
                                                 split 64-bit values (gpu alloc prints buffer VAs)
As a module: from pm4 import Asm; a = Asm(); a.pkt7('CP_NOP'); a.write('x.bin').
"""
import os, re, struct, sys
import xml.etree.ElementTree as ET

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
XML = os.path.join(ROOT, 'reference-repos/mesa/src/freedreno/registers/adreno')
GEN = 6


def _applies(variants):
    """Mesa variants strings like 'A6XX-A7XX', 'A7XX-', 'A6XX', 'A5XX,A6XX'."""
    if not variants:
        return True
    for part in variants.split(','):
        m = re.fullmatch(r'A(\d)XX(-(A(\d)XX)?)?', part.strip())
        if not m:
            continue
        lo = int(m.group(1))
        hi = lo if not m.group(2) else (int(m.group(4)) if m.group(4) else 99)
        if lo <= GEN <= hi:
            return True
    return False


def _strip(tree):
    for el in tree.iter():
        if '}' in el.tag:
            el.tag = el.tag.split('}', 1)[1]
    return tree


_ops = _regs = None


def ops():
    global _ops
    if _ops is None:
        t = _strip(ET.parse(os.path.join(XML, 'adreno_pm4.xml')))
        _ops = {}
        for enum in t.iter('enum'):
            if enum.get('name') != 'adreno_pm4_type3_packets':
                continue
            for v in enum.iter('value'):
                if v.get('value') and _applies(v.get('variants')):
                    _ops.setdefault(v.get('name'), int(v.get('value'), 0))
    return _ops


def regs():
    global _regs
    if _regs is None:
        t = _strip(ET.parse(os.path.join(XML, 'a6xx.xml')))
        _regs = {}
        for dom in t.iter('domain'):
            if dom.get('name') != 'A6XX':
                continue
            for el in dom:
                if not _applies(el.get('variants')):
                    continue
                name, off = el.get('name'), el.get('offset')
                if not name or off is None:
                    continue
                off = int(off, 0)
                if el.tag in ('reg32', 'reg64'):
                    _regs.setdefault(name, off)
                elif el.tag == 'array':
                    stride, length = int(el.get('stride', '1'), 0), int(el.get('length', '1'), 0)
                    kids = [k for k in el if k.tag in ('reg32', 'reg64') and _applies(k.get('variants'))]
                    for i in range(length):
                        base = off + i * stride
                        _regs.setdefault(f'{name}[{i}]', base)
                        for k in kids:
                            _regs.setdefault(f'{name}[{i}].{k.get("name")}', base + int(k.get('offset'), 0))
    return _regs


def parity(v):
    return (0x9669 >> (0xf & (v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^ (v >> 20) ^
                              (v >> 24) ^ (v >> 28)))) & 1


def pkt7_hdr(op, cnt):
    return 0x70000000 | cnt | (parity(cnt) << 15) | ((op & 0x7f) << 16) | (parity(op) << 23)


def pkt4_hdr(reg, cnt):
    return 0x40000000 | cnt | (parity(cnt) << 7) | ((reg & 0x3ffff) << 8) | (parity(reg) << 27)


class Asm:
    def __init__(self):
        self.dw = []
        self.sym = {}

    def num(self, s):
        if isinstance(s, int):
            return s
        m = re.fullmatch(r'(lo|hi)\((.+)\)', s)
        if m:
            v = self.num(m.group(2))
            return v & 0xffffffff if m.group(1) == 'lo' else (v >> 32) & 0xffffffff
        if s.startswith('@'):
            return self.sym[s[1:]]
        return int(s, 0)

    def pkt7(self, op, *vals):
        op = ops()[op] if isinstance(op, str) and not op[0].isdigit() else self.num(op)
        self.dw += [pkt7_hdr(op, len(vals))] + [self.num(v) & 0xffffffff for v in vals]

    def pkt4(self, reg, *vals):
        reg = regs()[reg] if isinstance(reg, str) and not reg[0].isdigit() else self.num(reg)
        self.dw += [pkt4_hdr(reg, len(vals))] + [self.num(v) & 0xffffffff for v in vals]

    def line(self, text):
        text = text.split('#', 1)[0].strip()
        if not text:
            return
        m = re.fullmatch(r'@(\w+)\s*=\s*(\S+)', text)
        if m:
            self.sym[m.group(1)] = self.num(m.group(2))
            return
        w = text.split()
        if w[0] == 'pkt7':
            self.pkt7(w[1], *w[2:])
        elif w[0] == 'pkt4':
            self.pkt4(w[1], *w[2:])
        elif w[0] == 'dw':
            self.dw += [self.num(v) & 0xffffffff for v in w[1:]]
        else:
            raise SystemExit(f'pm4: unknown line: {text}')

    def write(self, path):
        open(path, 'wb').write(struct.pack(f'<{len(self.dw)}I', *self.dw))


def main(argv):
    if len(argv) == 2 and argv[0] == '--op':
        print(hex(ops()[argv[1]]))
    elif len(argv) == 2 and argv[0] == '--reg':
        print(hex(regs()[argv[1]]))
    elif len(argv) == 2:
        a = Asm()
        for n, line in enumerate(open(argv[0]), 1):
            try:
                a.line(line)
            except (KeyError, ValueError) as e:
                raise SystemExit(f'{argv[0]}:{n}: {e}')
        a.write(argv[1])
        print(f'{argv[1]}: {len(a.dw)} dwords')
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
