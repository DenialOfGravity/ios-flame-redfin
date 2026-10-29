#!/usr/bin/env python3
"""python3 -I tools/test_soc_args.py: tools/soc-args.py's FDT parser and --check on a small DTB made here (no
phone tree in git: AGENTS.md). The tree mimics redfin's shapes: 2+2 cells under /, 1+1 under /soc with a
`ranges` that is identity (empty) or an offset, reserved-memory by phandle, tcsr-mutex hwlocks via syscon."""
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.path.join(HERE, 'soc-args.py')
spec = importlib.util.spec_from_file_location('soc_args', S)
sa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sa)


def u32(*v):
    return struct.pack('>%dI' % len(v), *v)


def s(*v):
    return b''.join(x.encode() + b'\0' for x in v)


def fdt(tree):
    """tree: (name, [(prop, bytes)], [children]) -> DTB bytes (version 17)."""
    strings, offs, out = bytearray(), {}, bytearray()

    def soff(n):
        if n not in offs:
            offs[n] = len(strings)
            strings.extend(n.encode() + b'\0')
        return offs[n]

    def node(t):
        name, props, kids = t
        out.extend(u32(1))
        nb = name.encode() + b'\0'
        out.extend(nb + b'\0' * (-len(nb) % 4))
        for k, v in props:
            out.extend(u32(3, len(v), soff(k)))
            out.extend(v + b'\0' * (-len(v) % 4))
        out.extend(u32(4))                          # a NOP, which the parser must skip
        for c in kids:
            node(c)
        out.extend(u32(2))

    node(tree)
    out.extend(u32(9))
    hdr = 40
    rsv = u32(0, 0, 0, 0)
    off_rsv = hdr
    off_struct = off_rsv + len(rsv)
    off_strings = off_struct + len(out)
    total = off_strings + len(strings)
    head = u32(0xd00dfeed, total, off_struct, off_strings, off_rsv, 17, 16, 0, len(strings), len(out))
    return head + rsv + bytes(out) + bytes(strings)


def redfin_like(soc_ranges=b'', smem=0x80900000):
    rm = ('reserved-memory', [('#address-cells', u32(2)), ('#size-cells', u32(2)), ('ranges', b'')], [
        ('smem_region@80900000', [('reg', u32(0, smem, 0, 0x200000)), ('phandle', u32(0x10))], []),
        ('pil_adsp_region@89200000', [('reg', u32(0, 0x89200000, 0, 0x2800000)), ('phandle', u32(0x11))], []),
        ('pil_wlan_fw_region@8ba00000', [('reg', u32(0, 0x8ba00000, 0, 0x200000)), ('phandle', u32(0x12))], []),
        ('modem_wlan_region@8c000000', [('reg', u32(0, 0x8c000000, 0, 0x11800000)), ('phandle', u32(0x13))], []),
        ('pil_gpu_region@8bc15400', [('reg', u32(0, 0x8bc15400, 0, 0x2000))], []),
        ('kregistry_mem@C8000000', [('reg', u32(0, 0xc8000000, 0, 0x10000))], []),
    ])
    kids = [
        ('syscon@1f40000', [('compatible', s('syscon')), ('reg', u32(0x1f40000, 0x20000)), ('phandle', u32(0x20))], []),
        ('hwlock', [('compatible', s('qcom,tcsr-mutex')), ('syscon', u32(0x20, 0, 0x1000)), ('phandle', u32(0x21))], []),
        ('qcom,smem', [('compatible', s('qcom,smem')), ('memory-region', u32(0x10)), ('hwlocks', u32(0x21, 3))], []),
        ('apps-smmu@15000000', [('compatible', s('qcom,qsmmu-v500')), ('reg', u32(0x15000000, 0x100000, 0x15182000, 0x20))], []),
        ('qcom,qmp-aop@c300000', [('compatible', s('qcom,qmp-mbox')), ('reg', u32(0xc300000, 0x1000))], []),
        ('qcom,ipcc@408000', [('compatible', s('qcom,ipcc')), ('reg', u32(0x408000, 0x1000))], []),
        ('tsens@c222000', [('compatible', s('qcom,tsens26xx')), ('reg', u32(0xc222000, 8, 0xc263000, 0x1ff))], []),
        ('tsens@c223000', [('compatible', s('qcom,tsens26xx')), ('reg', u32(0xc223000, 8, 0xc265000, 0x1ff))], []),
        ('qcom,kgsl-3d0@3d00000', [('compatible', s('qcom,kgsl-3d0', 'qcom,kgsl-3d')),
                                   ('reg', u32(0x3d00000, 0x40000, 0x3d61000, 0x800, 0x3de0000, 0x1000)),
                                   ('reg-names', s('kgsl_3d0_reg_memory', 'cx_dbgc', 'rscc'))], []),
        ('qcom,gpucc@3d90000', [('compatible', s('qcom,lito-gpucc', 'syscon')), ('reg', u32(0x3d90000, 0x9000))], []),
        ('kgsl-smmu@3da0000', [('compatible', s('qcom,qsmmu-v500')), ('reg', u32(0x3da0000, 0x10000))], []),
        ('qcom,lpass@3000000', [('compatible', s('qcom,pil-tz-generic')), ('reg', u32(0x3000000, 0x100)), ('memory-region', u32(0x11))], []),
        ('qcom,mss@4080000', [('compatible', s('qcom,pil-tz-generic')), ('reg', u32(0x4080000, 0x100)), ('memory-region', u32(0x13))], []),
        ('qcom,icnss@18800000', [('compatible', s('qcom,icnss')), ('reg', u32(0x18800000, 0x800000)),
                                 ('qcom,wlan-msa-fixed-region', u32(0x12))], []),
        ('qcom,qupv3_0_geni_se@8c0000', [('compatible', s('qcom,qupv3-geni-se')), ('reg', u32(0x8c0000, 0x2000))], []),
        ('qcom,qupv3_1_geni_se@9c0000', [('compatible', s('qcom,qupv3-geni-se')), ('reg', u32(0x9c0000, 0x2000))], []),
        ('qcom,qup_uart@894000', [('compatible', s('qcom,msm-geni-serial-hs')), ('reg', u32(0x894000, 0x4000))], []),
        ('i2c@98c000', [('compatible', s('qcom,i2c-geni')), ('reg', u32(0x98c000, 0x4000)),
                        ('#address-cells', u32(1)), ('#size-cells', u32(0))], [
            ('drv2624@5a', [('compatible', s('ti,drv2624')), ('reg', u32(0x5a))], [])]),
        ('qcom,gcc@100000', [('compatible', s('qcom,gcc-lito', 'syscon')), ('reg', u32(0x100000, 0x1f0000))], []),
        ('qcom,camcc@ad00000', [('compatible', s('qcom,lito-camcc', 'syscon')), ('reg', u32(0xad00000, 0x10000))], []),
    ]
    soc = ('soc', [('#address-cells', u32(1)), ('#size-cells', u32(1)), ('ranges', soc_ranges)], kids)
    return fdt(('', [('model', s('test redfin')), ('compatible', s('google,redfin-sm7250', 'qcom,sm7250')),
                     ('#address-cells', u32(2)), ('#size-cells', u32(2))], [rm, soc]))


def run(path, *a):
    r = subprocess.run([sys.executable, '-I', S, path, *a], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def write(self, blob):
        p = os.path.join(self.d, 'fdt')
        open(p, 'wb').write(blob)
        return p

    def test_parse_tree(self):
        root = sa.parse(redfin_like())
        paths = [n.path for n in root.walk()]
        self.assertIn('/soc/i2c@98c000/drv2624@5a', paths)
        self.assertIn('/reserved-memory/smem_region@80900000', paths)
        kgsl = next(n for n in root.walk() if n.name.startswith('qcom,kgsl-3d0'))
        self.assertEqual(kgsl.strs('compatible'), ['qcom,kgsl-3d0', 'qcom,kgsl-3d'])
        self.assertEqual(sa.regs(kgsl)[2], (0x3de0000, 0x1000))

    def test_check_all_agree(self):
        rc, out = run(self.write(redfin_like()), '--check')
        self.assertEqual(rc, 0, out)
        self.assertIn(f'{len(sa.CODE)} of {len(sa.CODE)} agree', out)

    def test_args_output(self):
        rc, out = run(self.write(redfin_like()))
        self.assertEqual(rc, 0, out)
        self.assertIn('soc_smem=0x80900000  # /soc/qcom,smem memory-region -> /reserved-memory/smem_region@80900000', out)
        self.assertIn('soc_smem_lock=0x1f43000', out)
        self.assertIn('soc_haptics_se=0x98c000', out)
        self.assertIn('soc_qup0_wrapper=0x8c0000', out)

    def test_difference_found(self):
        rc, out = run(self.write(redfin_like(smem=0x86000000)), '--check')    # sm8150's SMEM
        self.assertEqual(rc, 1)
        self.assertRegex(out, r'DIFF\s+smem\s')

    def test_ranges_translate(self):
        # /soc's children at bus address 0 map to CPU 0x1000000: every /soc address moves by that much
        root = sa.parse(redfin_like(soc_ranges=u32(0, 0, 0x1000000, 0x40000000)))
        ipcc = next(n for n in root.walk() if n.name.startswith('qcom,ipcc'))
        self.assertEqual(sa.regs(ipcc), [(0x1408000, 0x1000)])
        rc, out = run(self.write(redfin_like(soc_ranges=u32(0, 0, 0x1000000, 0x40000000))), '--check')
        self.assertEqual(rc, 1)
        self.assertRegex(out, r'DIFF\s+ipcc')

    def test_missing_node(self):
        blob = redfin_like().replace(b'camcc', b'xxxxx')    # node name and compatible
        rc, out = run(self.write(blob), '--check')
        self.assertEqual(rc, 1)
        self.assertRegex(out, r'MISSING\s+camcc')

    def test_not_fdt(self):
        rc, out = run(self.write(b'ADT\0' * 20))
        self.assertEqual(rc, 2)
        self.assertIn('not an FDT', out)


if __name__ == '__main__':
    unittest.main()
