#!/usr/bin/env python3
"""Tests of tools/redfin-camtune.py on made-up tuning files (no vendor file is needed or used): a container laid out
as the sensor module files are (tools/redfin-camtab.py), colour matrices, lens shading and reference lights with
their triggers among noise, in each encoding the tool tries; the .isp it writes read back by camera_isp.c itself
(phone/audio/isp_hosttest.c, built with the host's cc) where there is a compiler.

  python3 tools/test_redfin_camtune.py
"""
import importlib.util
import json
import math
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('camtune', os.path.join(HERE, 'redfin-camtune.py'))
camtune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(camtune)

GRID = 17 * 13

CCMS = {
    # lux range -> [(cct range, matrix)]
    (0.0, 250.0): [((2000.0, 3200.0), [1.9, -0.6, -0.3, -0.35, 1.6, -0.25, -0.1, -0.9, 2.0]),
                   ((3300.0, 4500.0), [1.8, -0.55, -0.25, -0.3, 1.55, -0.25, -0.05, -0.7, 1.75]),
                   ((4600.0, 7500.0), [1.7, -0.5, -0.2, -0.25, 1.5, -0.25, 0.0, -0.6, 1.6])],
    (300.0, 450.0): [((2000.0, 4000.0), [1.5, -0.35, -0.15, -0.2, 1.35, -0.15, 0.0, -0.4, 1.4]),
                     ((4100.0, 7500.0), [1.4, -0.3, -0.1, -0.15, 1.3, -0.15, 0.0, -0.35, 1.35])],
}
REFS = [(0.42, 0.78, 7500), (0.46, 0.70, 6500), (0.52, 0.60, 5000), (0.58, 0.55, 4100), (0.63, 0.50, 3800), (0.80, 0.40, 2850),
        (0.95, 0.33, 2300)]


def grid(strength, colour):
    g = []
    for y in range(13):
        for x in range(17):
            dx, dy = (x - 8) / 8, (y - 6) / 6
            g.append(1 + strength * (1 + 0.1 * colour) * (dx * dx + dy * dy))
    return g


def build(encoding, refs_cct=True, with_gain=True, seed=7):
    """a made-up com.qti.tuned file: (bytes, what is in it)"""
    rnd = random.Random(seed)
    vals = []           # (value, is_int)

    def noise(n):
        for _ in range(n):
            vals.append((rnd.choice([rnd.uniform(-1e4, 1e4), rnd.randint(0, 50), rnd.uniform(0, 1)]), False))

    def put(*xs, ints=False):
        vals.extend((x, ints) for x in xs)

    noise(57)
    for lux, entries in CCMS.items():
        put(1, ints=True)                                       # trigger hint
        put(*lux)
        if with_gain:
            put(1.0, 8.0)                                       # gain trigger
        for cct, m in entries:
            put(*cct)
            put(*m)
            put(0.0, 0.0, 0.0)                                  # k_tab
        noise(5)
    noise(31)
    lsc_tables = []
    for lux, strength in (((0.0, 300.0), 1.0), ((320.0, 500.0), 0.6)):
        put(2, ints=True)
        put(*lux)
        if with_gain:
            put(1.0, 16.0)
        for cct in ((2000.0, 4000.0), (4100.0, 7500.0)):
            put(*cct)
            grids = [grid(strength * (1.1 if cct[0] < 3000 else 1.0), c) for c in range(4)]
            for g in grids:
                put(*g)
            lsc_tables.append((lux, cct, grids))
        noise(3)
    noise(40)
    for rg, bg, cct in REFS:
        put(rg, bg)
        put(cct, ints=not refs_cct)
        put(1.0)
    noise(23)

    data = bytearray()
    for x, is_int in vals:
        if encoding == 'f32':
            data += struct.pack('<i', int(x)) if is_int else struct.pack('<f', x)
        elif encoding == 'f64':
            data += struct.pack('<q', int(x)) if is_int else struct.pack('<d', x)
        else:   # f32lo: 32-bit floats in 64-bit slots
            data += struct.pack('<q', int(x)) if is_int else struct.pack('<fI', x, 0)
    head = bytearray(0x100)
    head[0:20] = b'QTI Chromatix Header'
    head[0x20:0x20 + 23] = b'Parameter Parser V2.0.0'
    symtab = struct.pack('<Q32sQQQQ', 1, b'mod_cc13_aec_data', 0, 0, 0, len(data))
    struct.pack_into('<QQ', head, 0xa8, 0x100, len(symtab))
    struct.pack_into('<QQ', head, 0xc0, 0x100 + len(symtab), len(data))
    return bytes(head + symtab + data), lsc_tables


class CamTune(unittest.TestCase):
    def run_tool(self, blob, *args):
        d = tempfile.mkdtemp()
        try:
            path = os.path.join(d, 'tuned.bin')
            with open(path, 'wb') as fp:
                fp.write(blob)
            out = os.path.join(d, 'out.isp')
            js = os.path.join(d, 'found.json')
            camtune.main([path, '-o', out, '--json', js] + list(args))
            with open(out, 'rb') as fp, open(js) as fj:
                return fp.read(), json.load(fj)
        finally:
            shutil.rmtree(d)

    def check(self, tuning, refs_exact=True):
        self.assertEqual(len(tuning['ccm']), 2)
        for light, (lux, entries) in zip(tuning['ccm'], sorted(CCMS.items())):
            self.assertEqual(tuple(light['lux']), lux)
            self.assertEqual(len(light['ccts']), len(entries))
            for e, (cct, m) in zip(light['ccts'], entries):
                self.assertEqual(tuple(e['cct']), cct)
                for a, b in zip(e['m'], m):
                    self.assertAlmostEqual(a, b, places=5)
        self.assertEqual(len(tuning['lsc']), 2)
        self.assertEqual(tuple(tuning['lsc'][0]['lux']), (0.0, 300.0))
        self.assertEqual(len(tuning['lsc'][0]['ccts']), 2)
        self.assertAlmostEqual(tuning['lsc'][0]['ccts'][0]['grids'][0][0], grid(1.1, 0)[0], places=4)
        self.assertEqual(len(tuning['refs']), len(REFS))
        # bluest first
        self.assertAlmostEqual(tuning['refs'][0][0], REFS[0][0], places=5)
        self.assertAlmostEqual(tuning['refs'][-1][1], REFS[-1][1], places=5)
        if refs_exact:
            self.assertEqual([round(r[2]) for r in tuning['refs']], [r[2] for r in REFS])
        else:
            self.assertAlmostEqual(tuning['refs'][0][2], 7500, delta=1)
            self.assertAlmostEqual(tuning['refs'][-1][2], 2300, delta=1)

    def test_encodings(self):
        for enc in ('f32', 'f64', 'f32lo'):
            with self.subTest(encoding=enc):
                blob, _ = build(enc)
                isp, tuning = self.run_tool(blob)
                self.assertEqual(isp[:8], b'RWCISP02')
                self.check(tuning)

    def test_no_gain_trigger_and_integer_cct(self):
        blob, _ = build('f64', refs_cct=False, with_gain=False)
        _, tuning = self.run_tool(blob)
        self.check(tuning, refs_exact=False)

    def test_ccm_order(self):
        blob, _ = build('f32')
        _, tuning = self.run_tool(blob, '--ccm-order', 'gbr')
        m = CCMS[(0.0, 250.0)][0][1]
        # (the file's rows/columns G, B, R: its [2][2] is R's own)
        self.assertAlmostEqual(tuning['ccm'][0]['ccts'][0]['m'][0], m[8], places=5)

    def test_layout_and_c_reader(self):
        blob, _ = build('f32')
        isp, tuning = self.run_tool(blob)
        # the layout, by hand
        p = 8
        lights, = struct.unpack_from('<I', isp, p)
        p += 4
        self.assertEqual(lights, 2)
        lux0, lux1, ccts = struct.unpack_from('<ffI', isp, p)
        self.assertEqual((lux0, lux1, ccts), (0.0, 250.0, 3))
        # camera_isp.c's own reader, where the host can build it
        cc = shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
        if cc is None:
            self.skipTest('no C compiler')
        audio = os.path.join(HERE, '..', 'phone', 'audio')
        d = tempfile.mkdtemp()
        try:
            exe = os.path.join(d, 'isp_hosttest')
            subprocess.check_call([cc, '-O1', '-I', audio, os.path.join(audio, 'isp_hosttest.c'), os.path.join(audio, 'camera_isp.c'),
                                   '-lm', '-o', exe])
            path = os.path.join(d, 'out.isp')
            with open(path, 'wb') as fp:
                fp.write(isp)
            out = subprocess.check_output([exe, 'tuning', path, '100', '2600']).decode()
            lines = dict(l.split(' ', 1) for l in out.strip().split('\n'))
            self.assertEqual(lines['lights'], '2 2 refs 7')
            m = [float(x) for x in lines['ccm'].split()]
            for a, b in zip(m, CCMS[(0.0, 250.0)][0][1]):
                self.assertAlmostEqual(a, b, places=3)
            lsc = [float(x) for x in lines['lsc'].split()]
            self.assertAlmostEqual(lsc[0], 1.0, places=3)                      # the centre
            self.assertAlmostEqual(lsc[1], grid(1.1, 0)[0], places=3)          # R's corner
            self.assertAlmostEqual(float(lines['cct']), 7500, delta=1)
        finally:
            shutil.rmtree(d)

    def test_nothing_found(self):
        rnd = random.Random(3)
        blob = struct.pack('<4096f', *[rnd.uniform(-5, 5) for _ in range(4096)])
        isp, tuning = self.run_tool(blob)
        self.assertEqual(isp[:8], b'RWCISP02')
        self.assertEqual(tuning['refs'], [])


if __name__ == '__main__':
    unittest.main()
