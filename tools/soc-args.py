#!/usr/bin/env python3
"""The SM7250 (lito) addresses the redfin port hard-codes, read back from a phone's own flattened device tree,
so that they can be cross-checked (the HakiOS vayu port's soc.args convention). Pure Python, no dependencies.

  python3 -I tools/soc-args.py DTB             KEY=VALUE lines (soc.args), each with the DT node it came from
  python3 -I tools/soc-args.py DTB --check     compare with the values the code uses (CODE below):
                                               exit 0 when all agree, 1 on a difference or a node not found
  python3 -I tools/soc-args.py --table         the values the code uses, and where

DTB: /sys/firmware/fdt as devices/redfin/pull-soc.sh pulls it (the live tree ABL hands over). Not Apple's ADT.
Addresses are CPU physical: a node's reg is translated through its parents' `ranges` (empty = identity).

Every CODE row: the key, the value the code uses, where (patch or file), and how the node is found in the DT.
When the code changes an address, change its row here in the same commit.
"""
import re
import struct
import sys

# --- the values the code uses ------------------------------------------------------------------------------
# finders: ('compat', REGEX, REG_INDEX)          nodes whose compatible matches
#          ('name', REGEX, REG_INDEX)            nodes whose name (with unit address) matches
#          ('regname', COMPAT_REGEX, REG_NAME)   the reg entry named REG_NAME (reg-names) of a compatible node
#          ('mem', NAME_OR_COMPAT_REGEX, PROP)   the node a phandle property (memory-region, qcom,wlan-msa-...)
#                                                of the matching node points at, its first reg
#          ('parent', COMPAT_REGEX)              the parent of a compatible node (a bus controller)
#          ('hwlock', COMPAT_REGEX)              the TCSR mutex block of a node's `hwlocks`: (base, lock index)
CODE = [
    ('smem', 0x80900000, 'xnu 0915 SMEM_PHYS; phone/wifi/smem.h SMEM_BASE', ('mem', r'^qcom,smem$', 'memory-region')),
    ('smem_size', 0x200000, 'xnu 0915 SMEM_SIZE', ('mem-size', r'^qcom,smem$', 'memory-region')),
    ('tcsr_mutex', 0x1f40000, 'phone/wifi/smem.c TCSR_MUTEX(n)', ('hwlock', r'^qcom,smem$')),
    ('smem_lock', 0x1f43000, 'xnu 0915 smem_lock (TCSR mutex + 0x1000 x hwlocks index)', ('hwlock-pa', r'^qcom,smem$')),
    ('apps_smmu', 0x15000000, 'xnu 0921/0948/0950/0952 SMMU_PA; phone/wifi/radio.c SMMU_PA', ('name', r'^apps-smmu@', 0)),
    ('aoss_qmp', 0xc300000, 'xnu 0915 aoss; phone/wifi/wland.c QMP_RAM', ('compat', r'^qcom,qmp-mbox$', 0)),
    ('ipcc', 0x408000, 'xnu 0915 ipcc; phone/wifi/ipcc.h IPCC_BASE', ('compat', r'^qcom,ipcc$', 0)),
    ('tsens0_tm', 0xc263000, 'xnu 0960 tsens0 TM', ('compat', r'^qcom,tsens', 1)),
    ('tsens1_tm', 0xc265000, 'xnu 0960 tsens1 TM', ('compat', r'^qcom,tsens', 1)),
    ('gpu', 0x3d00000, 'xnu 0904 A6_GPU_BASE', ('compat', r'^qcom,kgsl-3d0$', 0)),
    ('gpu_rscc', 0x3de0000, 'xnu 0904 RSCC', ('regname', r'^qcom,kgsl-3d0$', 'rscc')),
    ('gpucc', 0x3d90000, 'xnu 0904 A6_GPUCC', ('compat', r'gpucc', 0)),
    ('gpu_smmu', 0x3da0000, 'xnu 0904 A6_SMMU', ('name', r'^kgsl-smmu@', 0)),
    ('gpu_zap', 0x8bc15400, 'xnu 0904 (pil_gpu_region, a620_zap)', ('name', r'^pil_gpu_region', 0)),
    ('kregistry', 0xc8000000, 'xnu 0904 (GPU pool avoids it)', ('name', r'^kregistry_mem', 0)),
    ('adsp_mem', 0x89200000, 'xnu 0915 ADSP_MEMORY', ('mem', r'^qcom,lpass@', 'memory-region')),
    ('adsp_mem_size', 0x2800000, 'xnu 0915 ADSP_MEMORY_SIZE', ('mem-size', r'^qcom,lpass@', 'memory-region')),
    ('mpss_mem', 0x8c000000, 'phone/wifi/wland.c MPSS_PA', ('mem', r'^qcom,mss@', 'memory-region')),
    ('mpss_mem_size', 0x11800000, 'phone/wifi/wland.c MPSS_SIZE', ('mem-size', r'^qcom,mss@', 'memory-region')),
    ('wlan_msa', 0x8ba00000, 'phone/wifi/wlfw.c MSA_PA', ('mem', r'^qcom,icnss$', 'qcom,wlan-msa-fixed-region')),
    ('wlan_wcss', 0x18800000, 'phone/wifi/radio.c WLAN_PA, ath.c WCSS', ('compat', r'^qcom,icnss$', 0)),
    ('qup0_wrapper', 0x8c0000, 'xnu 0981 GU_WRAP_PA; phone/bt/geni.c WRAP0', ('compat', r'^qcom,qupv3-geni-se$', 0)),
    ('bt_uart_se', 0x894000, 'xnu 0981 GU_SE_PA; phone/bt/geni.c SE', ('compat', r'^qcom,msm-geni-serial-hs$', 0)),
    ('haptics_se', 0x98c000, 'xnu 0907 HAP_SE_PA (DRV2624 bus)', ('parent', r'^ti,drv2624$')),
    ('gcc', 0x100000, 'xnu 0907 HAP_GCC_PA; phone/bt/geni.c GCC', ('compat', r'^qcom,gcc-', 0)),
    ('camcc', 0xad00000, 'xnu 0921 CAMCC_PA', ('compat', r'camcc', 0)),
]
# a selector that finds several nodes keeps them all (--check agrees when the code's value is one of them),
# except these: the n-th hit by address (two TSENS controllers; QUP wrapper 0 of two)
NTH = {'tsens0_tm': 0, 'tsens1_tm': 1, 'qup0_wrapper': 0}


# --- FDT ---------------------------------------------------------------------------------------------------
class Node:
    def __init__(self, name, parent):
        self.name, self.parent, self.props, self.children = name, parent, {}, []

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

    def cells(self, prop):
        v = self.props.get(prop)
        return None if v is None else list(struct.unpack('>%dI' % (len(v) // 4), v[:len(v) // 4 * 4]))

    def strs(self, prop):
        v = self.props.get(prop)
        return [] if not v else [s.decode(errors='replace') for s in v.rstrip(b'\0').split(b'\0')]

    def ncells(self, prop, default):
        c = self.cells(prop)
        return c[0] if c else default


def parse(blob):
    if len(blob) < 40:
        raise ValueError('too short for an FDT')
    magic, total, off_struct, off_strings = struct.unpack_from('>4I', blob, 0)
    if magic != 0xd00dfeed:
        raise ValueError('not an FDT (magic %#x)' % magic)
    p, root, cur = off_struct, None, None
    while True:
        tok, = struct.unpack_from('>I', blob, p)
        p += 4
        if tok == 1:                                    # FDT_BEGIN_NODE
            end = blob.index(b'\0', p)
            n = Node(blob[p:end].decode() or '/', cur)
            p = (end + 4) & ~3
            if cur is None:
                root = n
            else:
                cur.children.append(n)
            cur = n
        elif tok == 2:                                  # FDT_END_NODE
            cur = cur.parent
        elif tok == 3:                                  # FDT_PROP
            ln, nameoff = struct.unpack_from('>II', blob, p)
            p += 8
            s = off_strings + nameoff
            cur.props[blob[s:blob.index(b'\0', s)].decode()] = bytes(blob[p:p + ln])
            p = (p + ln + 3) & ~3
        elif tok == 4:                                  # FDT_NOP
            continue
        elif tok == 9:                                  # FDT_END
            return root
        else:
            raise ValueError(f'bad token {tok:#x} at {p - 4:#x}')


def num(cells):
    v = 0
    for c in cells:
        v = v << 32 | c
    return v


def translate(node, addr):
    """A child address of node's bus up to a CPU address, through each ancestor's ranges."""
    bus = node.parent
    while bus is not None and bus.parent is not None:
        r = bus.props.get('ranges')
        if r is None:
            return None                                  # no ranges: not memory-mapped
        if r:
            ca = bus.ncells('#address-cells', 2)
            pa = bus.parent.ncells('#address-cells', 2)
            sc = bus.ncells('#size-cells', 1)
            c, step, hit = bus.cells('ranges'), ca + pa + sc, None
            for i in range(0, len(c) - step + 1, step):
                child, parent, size = num(c[i:i + ca]), num(c[i + ca:i + ca + pa]), num(c[i + ca + pa:i + step])
                if child <= addr < child + size:
                    hit = addr - child + parent
                    break
            if hit is None:
                return None
            addr = hit
        bus = bus.parent
    return addr


def regs(node):
    """reg as [(cpu address, size)], with the parent's #address-cells/#size-cells."""
    c = node.cells('reg')
    if not c or node.parent is None:
        return []
    ac, sc = node.parent.ncells('#address-cells', 2), node.parent.ncells('#size-cells', 1)
    out = []
    for i in range(0, len(c) - ac - sc + 1, ac + sc):
        a = translate(node, num(c[i:i + ac]))
        if a is not None:
            out.append((a, num(c[i + ac:i + ac + sc])))
    return out


def phandles(root):
    return {n.cells(k)[0]: n for n in root.walk() for k in ('phandle', 'linux,phandle') if n.cells(k)}


# --- finding ------------------------------------------------------------------------------------------------
def select(root, rx):
    """Nodes whose name or any compatible matches rx."""
    r = re.compile(rx)
    return [n for n in root.walk() if r.search(n.name) or any(r.search(c) for c in n.strs('compatible'))]


def find(root, ph, how):
    """[(value, where)] for one finder."""
    kind, out = how[0], []
    if kind in ('compat', 'name'):
        r = re.compile(how[1])
        for n in root.walk():
            if (kind == 'name' and r.search(n.name)) or (kind == 'compat' and any(r.search(c) for c in n.strs('compatible'))):
                rg = regs(n)
                if len(rg) > how[2]:
                    out.append((rg[how[2]][0], f'{n.path} reg[{how[2]}] size {rg[how[2]][1]:#x}'))
    elif kind == 'regname':
        for n in select(root, how[1]):
            names, rg = n.strs('reg-names'), regs(n)
            if how[2] in names and names.index(how[2]) < len(rg):
                a, s = rg[names.index(how[2])]
                out.append((a, f'{n.path} reg "{how[2]}" size {s:#x}'))
    elif kind in ('mem', 'mem-size'):
        for n in select(root, how[1]):
            c = n.cells(how[2])
            t = ph.get(c[0]) if c else None
            rg = regs(t) if t is not None else []
            if rg:
                out.append((rg[0][0] if kind == 'mem' else rg[0][1], f'{n.path} {how[2]} -> {t.path}'))
    elif kind == 'parent':
        for n in select(root, how[1]):
            rg = regs(n.parent)
            if rg:
                out.append((rg[0][0], f'{n.parent.path} (bus of {n.name})'))
    elif kind in ('hwlock', 'hwlock-pa'):
        for n in select(root, how[1]):
            c = n.cells('hwlocks')
            t = ph.get(c[0]) if c else None
            if t is None:
                continue
            idx = c[1] if len(c) > 1 else 0
            block = t
            sc = t.cells('syscon')                       # qcom,tcsr-mutex: syscon = <&tcsr_mutex_regs base stride>
            if sc and sc[0] in ph:
                block = ph[sc[0]]
            rg = regs(block)
            if not rg:
                continue
            base = rg[0][0] + (sc[1] if sc and len(sc) > 1 else 0)
            stride = sc[2] if sc and len(sc) > 2 else 0x1000
            if kind == 'hwlock':
                out.append((base, f'{block.path} (hwlocks of {n.path}, stride {stride:#x})'))
            else:
                out.append((base + stride * idx, f'{block.path} + {stride:#x} x lock {idx} (hwlocks of {n.path})'))
    else:
        raise ValueError(kind)
    out = sorted(set(out))
    return out


def resolve(root):
    ph = phandles(root)
    rows = []
    for key, val, src, how in CODE:
        hits = find(root, ph, how)
        if key in NTH:
            hits = [hits[NTH[key]]] if len(hits) > NTH[key] else []
        rows.append((key, val, src, hits))
    return rows


def main(argv):
    if argv == ['--table']:
        for key, val, src, how in CODE:
            print(f'{key:14} {val:#12x}  {src}')
        return 0
    args = [a for a in argv if not a.startswith('--')]
    if len(args) != 1 or any(a not in ('--check',) for a in argv if a.startswith('--')):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        root = parse(open(args[0], 'rb').read())
    except (OSError, ValueError, struct.error) as e:
        print(f'soc-args: {args[0]}: {e}', file=sys.stderr)
        return 2
    rows = resolve(root)
    if '--check' not in argv:
        print(f'# soc-args.py: SoC addresses from {root.strs("model")[:1] or ["(no model)"]} '
              f'{root.strs("compatible")[:2]}; KEY=VALUE  # DT node')
        for key, val, src, hits in rows:
            if not hits:
                print(f'# soc_{key}: not found')
            for i, (v, where) in enumerate(hits):
                print(f'soc_{key}{"" if len(hits) == 1 else "." + str(i)}={v:#x}  # {where}')
        return 0
    bad = 0
    for key, val, src, hits in rows:
        if not hits:
            state, got = 'MISSING', 'no DT node'
        elif any(v == val for v, _ in hits):
            state, got = 'ok', next(w for v, w in hits if v == val)
        else:
            state, got = 'DIFF', ', '.join(f'{v:#x} {w}' for v, w in hits)
        bad += state != 'ok'
        print(f'{state:7} {key:14} code {val:#11x}  {src}\n        {"":14} dt   {got}')
    print(f'soc-args: {len(rows) - bad} of {len(rows)} agree' + ('' if not bad else f'; {bad} to look at'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
