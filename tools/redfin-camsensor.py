#!/usr/bin/env python3
"""Read a Pixel 5 camera sensor module file (Qualcomm CamX "QTI Chromatix Header", Parameter Parser V2.0.0):
the slave address, the chip ID read and the power sequences. The files are the vendor's
(/vendor/lib64/camera/com.qti.sensormodule.*_lito2.bin, pulled read-only by the phone agent's
twrp-pull-camera into recon/camera) and stay out of git.

  tools/redfin-camsensor.py MODULE.bin

Layout (found on redfin's three files): at 0xa8 the symbol table (u64 offset, u64 size), at 0xc0 the data
(u64 offset, u64 size). A symbol is { u64 id, char name[32], u64 kind, u64 parent, u64 offset, u64 size }
(0x48 bytes). The data starts with the sensor driver's slaveInfo as u64 words: [5] slave address (8-bit),
[7]/[8] register address/data type (2 = word), [9] the ID register, [10] the ID, [11] its mask, [12] the I2C
speed; then (count, symbol id) of the power-up and the power-down sequence, whose elements are
{ kind, 0, value, 0, delay ms, 0 } u32 (kinds: CamX's cam_sensor power types, below).
(HackiOS tools/camsensor.py reads the Parser V3 files of its phone the same way.)
"""
import struct
import sys

KIND = {0: 'MCLK', 1: 'VANA', 2: 'VDIG', 3: 'VIO', 4: 'VAF', 5: 'VAF_PWDM', 6: 'CUSTOM_REG1', 7: 'CUSTOM_REG2',
        8: 'RESET', 9: 'STANDBY', 10: 'CUSTOM_GPIO1', 11: 'CUSTOM_GPIO2'}


def load(path):
    d = open(path, 'rb').read()
    if not d.startswith(b'QTI Chromatix Header'):
        sys.exit(f'{path}: not a CamX module file')
    toff, tsz = struct.unpack_from('<QQ', d, 0xa8)
    doff, dsz = struct.unpack_from('<QQ', d, 0xc0)
    syms = {}
    for o in range(toff, toff + tsz, 0x48):
        sid, name, kind, parent, off, size = struct.unpack_from('<Q32sQQQQ', d, o)
        syms[sid] = (name.split(b'\0')[0].decode(), kind, parent, off, size)
    return d[doff:doff + dsz], syms


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    data, syms = load(sys.argv[1])
    w = struct.unpack_from('<17Q', data, 0)
    print('slave 0x%02x (7-bit 0x%02x), address type %d, data type %d, id register 0x%04x = 0x%04x (mask %#x), '
          'i2c mode %d' % (w[5], w[5] >> 1, w[7], w[8], w[9], w[10], w[11], w[12]))
    for label, count, sid in (('power-up', w[13], w[14]), ('power-down', w[15], w[16])):
        _, _, _, off, size = syms[sid]
        print(label)
        step = size // count
        for i in range(count):
            v = struct.unpack_from('<%dI' % (step // 4), data, off + i * step)
            print('   %-12s value %-9d delay %d ms' % (KIND.get(v[0], v[0]), v[2], v[4]))


if __name__ == '__main__':
    main()
