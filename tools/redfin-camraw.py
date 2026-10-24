#!/usr/bin/env python3
"""Make a picture of a raw camera frame from the kernel's capture path (bsd/dev/sweet_cam.c "poke c 20" /
"c 21", fetched with flame-files.py read /dev/pmem PA LEN FILE).

  tools/redfin-camraw.py FRAME WIDTH HEIGHT OUT.png [--cfa BGGR|GBRG|GRBG|RGGB|mono] [--stride BYTES] [--raw]

FRAME is MIPI RAW10 packed (5 bytes for 4 pixels: four high bytes, then the four pairs of low bits), lines
STRIDE bytes apart (default WIDTH * 10 / 8). The picture is half size: each 2x2 cell of the colour filter
gives one RGB pixel, the two greens averaged; grey-world white balance, black level 64, a 2.2 gamma. --raw
writes the sensor values as grey instead (full size, no colour). Needs numpy and Pillow.
"""
import argparse
import sys

import numpy as np
from PIL import Image


def unpack(data, width, height, stride):
    a = np.frombuffer(data, dtype=np.uint8)
    if a.size < stride * height:
        a = np.concatenate([a, np.zeros(stride * height - a.size, np.uint8)])
    a = a[:stride * height].reshape(height, stride)[:, :width * 5 // 4].reshape(height, width // 4, 5).astype(np.uint16)
    low = a[:, :, 4]
    px = np.empty((height, width // 4, 4), np.uint16)
    for k in range(4):
        px[:, :, k] = a[:, :, k] << 2 | (low >> (2 * k)) & 3
    return px.reshape(height, width)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('frame')
    ap.add_argument('width', type=int)
    ap.add_argument('height', type=int)
    ap.add_argument('out')
    ap.add_argument('--cfa', default='BGGR')
    ap.add_argument('--stride', type=int, default=0)
    ap.add_argument('--raw', action='store_true')
    o = ap.parse_args()
    stride = o.stride or o.width * 10 // 8
    data = open(o.frame, 'rb').read()
    v = unpack(data, o.width, o.height, stride).astype(np.float32)
    marker = np.frombuffer(data[:stride * o.height], dtype=np.uint32)
    print(f'{o.frame}: {len(data)} bytes; min {v.min():.0f} max {v.max():.0f} mean {v.mean():.1f}; '
          f'{np.count_nonzero(marker == 0x5a5a5a5a)} of {marker.size} words still the marker')
    if o.raw or o.cfa == 'mono':
        g = np.clip(v / 1023.0, 0, 1) ** (1 / 2.2)
        Image.fromarray((g * 255).astype(np.uint8), 'L').save(o.out)
        return
    pos = {c: [] for c in 'RGB'}
    for i, c in enumerate(o.cfa.upper()):
        pos[c].append((i // 2, i % 2))
    if len(pos['R']) != 1 or len(pos['B']) != 1 or len(pos['G']) != 2:
        sys.exit('--cfa: one of BGGR GBRG GRBG RGGB mono')
    h2, w2 = o.height // 2 * 2, o.width // 2 * 2
    v = np.maximum(v[:h2, :w2] - 64, 0)

    def plane(c):
        return sum(v[y::2, x::2] for y, x in pos[c]) / len(pos[c])
    rgb = np.stack([plane('R'), plane('G'), plane('B')], axis=2)
    means = rgb.reshape(-1, 3).mean(axis=0) + 1e-3
    rgb *= means[1] / means
    top = np.percentile(rgb, 99.5) or 1.0
    rgb = np.clip(rgb / top, 0, 1) ** (1 / 2.2)
    Image.fromarray((rgb * 255).astype(np.uint8), 'RGB').save(o.out)
    print(f'{o.out}: {w2 // 2}x{h2 // 2}, white balance {means[1] / means[0]:.2f} {means[1] / means[2]:.2f}')


main()
