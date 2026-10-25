#!/usr/bin/env python3
"""Read a Pixel 5 camera sensor module file (Qualcomm CamX "QTI Chromatix Header", Parameter Parser V2.0.0):
the slave address, the chip ID read and the power sequences; with -a also the module configuration and the
parts CamX bundles into the same file: the lens actuator's driver data, the OIS controller's, the EEPROM's and
the flash's. The files are the vendor's (/vendor/lib64/camera/com.qti.sensormodule.*_lito2.bin, pulled read-only
by the phone agent's twrp-pull-camera into recon/camera) and stay out of git, as does what this prints.

  tools/redfin-camsensor.py MODULE.bin          the sensor (as before)
  tools/redfin-camsensor.py -a MODULE.bin       and the module configuration, actuator, OIS, EEPROM, flash

Layout (found on redfin's three files): at 0xa8 the symbol table (u64 offset, u64 size), at 0xc0 the data
(u64 offset, u64 size). A symbol is { u64 id, char name[32], u64 kind, u64 parent, u64 offset, u64 size }
(0x48 bytes). Kind 1 symbols are the top-level structures (sensorDriverData, PDConfigData, cameraModuleData,
actuatorDriver, flashDriverData, OISDriver, EEPROMDriverData); every other value is a u64, and an array is a
(count, symbol id) pair. The data starts with the sensor driver's slaveInfo as u64 words: [5] slave address
(8-bit), [7]/[8] register address/data type (2 = word), [9] the ID register, [10] the ID, [11] its mask, [12] the
I2C speed; then (count, symbol id) of the power-up and the power-down sequence, whose elements are
{ kind, 0, value, 0, delay ms, 0 } u32 (kinds: CamX's cam_sensor power types, below).
(HackiOS tools/camsensor.py reads the Parser V3 files of its phone the same way.)

The other parts (found 2026-10-25 on metric_imx363_lito2; the words as CamX's actuatordriver/oisdriver/
eepromdriver XSDs order their elements):
  cameraModuleData  [0..2] version, [3,4] moduleConfiguration: { [0], then (count, symbol): moduleName, sensorName,
                    sensorSlaveAddress, sensorI2CFrequencyMode, actuatorName, oisName, eepromName,
                    eepromSlaveAddress, flashName, Name (chromatix), i2cFrequencyMode, ... } (strings: arrays)
  actuatorDriver    [0..2] version, [3,4] actuatorName, [5,6] actuatorID, [7] slave (8-bit), [8] I2C mode,
                    [9] actuator type, [10] data bit width, [11,12] power-up, [13,14] power-down,
                    [15,16] registerParam { address type, data type, register, register data (OR'ed into
                    every position write), operation, hw shift, hw mask, data shift, delay us },
                    [17,18] initSettings, [19,20] deInitSettings, [21] initial code, [22,23] regions
                    { macro step boundary, infinity step boundary, code per step (float), q value }, then
                    (count, scenario) twice: { ringing scenario (step boundary, damping step, damping delay) }
  OISDriver         [0..2] version, [3,4] OISName, [5] slave, [6] I2C mode, [7..8] opcode, [9..12] power-up/down,
                    then setting lists (count, symbol): firmware/init/calibration/enable/disable lists and the
                    named ones (enterDownloadModeSettings, movieModeSettings, stillModeSettings,
                    centeringOn/OffSettings, pantiltOnSettings, sceneOis/Filter/RangeSettings, updateGainSettings)
  EEPROMDriverData  name, power-up/down, then the memory map: one register-setting list (slave, register,
                    data, types, operation 3 = read that many bytes)
A register setting is 10 words { slave count, slave, register, data count, data, address type, data type,
operation, delay count, delay } (types 1 byte, 2 word, 4 dword; operation 0 write, 3 read, 4 poll until equal,
delay in us).
"""
import struct
import sys

KIND = {0: 'MCLK', 1: 'VANA', 2: 'VDIG', 3: 'VIO', 4: 'VAF', 5: 'VAF_PWDM', 6: 'CUSTOM_REG1', 7: 'CUSTOM_REG2',
        8: 'RESET', 9: 'STANDBY', 10: 'CUSTOM_GPIO1', 11: 'CUSTOM_GPIO2'}
I2C = {0: 'standard 100 kHz', 1: 'fast 400 kHz', 2: 'custom', 3: 'fast plus 1 MHz'}
OP = {0: 'write', 1: 'write burst', 2: 'write sequential', 3: 'read', 4: 'poll', 5: 'delay'}


def load(path):
    d = open(path, 'rb').read()
    if not d.startswith(b'QTI Chromatix Header'):
        sys.exit(f'{path}: not a CamX module file')
    toff, tsz = struct.unpack_from('<QQ', d, 0xa8)
    doff, dsz = struct.unpack_from('<QQ', d, 0xc0)
    syms = {}
    for o in range(toff, toff + tsz, 0x48):
        sid, name, kind, parent, off, size = struct.unpack_from('<Q32sQQQQ', d, o)
        syms[sid] = (name.split(b'\0')[0].decode('latin1'), kind, parent, off, size)
    return d[doff:doff + dsz], syms


class Module:
    def __init__(self, path):
        self.data, self.syms = load(path)

    def words(self, sid):
        _, _, _, off, size = self.syms[sid]
        return struct.unpack_from('<%dQ' % (size // 8), self.data, off)

    def top(self, name):
        for sid, (n, kind, _, off, size) in self.syms.items():
            if n == name and kind == 1:
                return struct.unpack_from('<%dQ' % (size // 8), self.data, off)
        return None

    def string(self, count, sid):
        """a string element: the bytes themselves, or an array of one string"""
        if sid not in self.syms:
            return ''
        n, _, _, off, size = self.syms[sid]
        raw = self.data[off:off + size]
        c, inner = struct.unpack_from('<QQ', raw, 0) if size == 16 else (0, 0)
        if size == 16 and 0 < c < 256 and inner in self.syms and inner != sid:
            return self.string(c, inner)
        return raw.split(b'\0')[0].decode('latin1')

    def scalar(self, sid):
        if sid not in self.syms or self.syms[sid][4] < 8:
            return None
        return self.words(sid)[0]

    def regsettings(self, count, sid):
        out = []
        if not count or sid not in self.syms:
            return out
        _, _, _, off, size = self.syms[sid]
        for e in range(off, off + min(size, 80 * count), 80):
            ns, ssid, reg, nd, dsid, at, dt, op, ndl, dlsid = struct.unpack_from('<10Q', self.data, e)
            slave = self.scalar(ssid) if ns else None
            vals = self.words(dsid)[:max(nd, 1)] if nd and dsid in self.syms and self.syms[dsid][4] else (0,)
            delay = self.scalar(dlsid) if ndl else 0
            out.append((slave, reg, vals, at, dt, op, delay or 0))
        return out


def show_regs(m, label, count, sid, limit=40):
    rs = m.regsettings(count, sid)
    print(f'  {label}: {len(rs)}')
    for slave, reg, vals, at, dt, op, delay in rs[:limit]:
        v = ' '.join('%#x' % x for x in vals[:4]) + (' ...' if len(vals) > 4 else '')
        print('     %s%-5s %#06x %s %-12s (%dB addr, %dB data)%s' % (
            '' if slave is None else 'slave %#x ' % slave, OP.get(op, op), reg, '<-' if op != 3 else 'n=', v, at, dt,
            f' then {delay} us' if delay else ''))
    if len(rs) > limit:
        print(f'     ... {len(rs) - limit} more')


def power(m, label, count, sid):
    if not count or sid not in m.syms:
        print(f'  {label}: none')
        return
    w = m.words(sid)
    step = len(w) // count
    print(f'  {label}: ' + ', '.join('%s %d +%d ms' % (KIND.get(w[i * step], w[i * step]), w[i * step + 1], w[i * step + 2])
                                    for i in range(count)))


def sensor(m):
    data, syms = m.data, m.syms
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


def module_config(m):
    cm = m.top('cameraModuleData')
    if not cm or len(cm) < 5:
        return
    mc = m.words(cm[4])
    names = ['moduleName', 'sensorName', 'sensorSlaveAddress', 'sensorI2CFrequencyMode', 'actuatorName', 'oisName',
             'eepromName', 'eepromSlaveAddress', 'flashName', 'Name', 'i2cFrequencyMode']
    print('module configuration:')
    for k, name in enumerate(names):
        i = 1 + 2 * k
        if i + 1 >= len(mc):
            break
        count, sid = mc[i], mc[i + 1]
        if not count:
            print(f'  {name}: -')
        elif name.endswith('Name') or name == 'Name':
            print(f'  {name}: {m.string(count, sid)}')
        else:
            print(f'  {name}: {m.scalar(sid)}')


def actuator(m):
    a = m.top('actuatorDriver')
    if not a:
        print('actuator: none')
        return
    print('actuator %s: slave %#x (7-bit %#x), I2C %s, type %d, %d-bit positions' % (
        m.string(a[3], a[4]) if a[3] else '?', a[7], a[7] >> 1, I2C.get(a[8], a[8]), a[9], a[10]))
    power(m, 'power-up', a[11], a[12])
    power(m, 'power-down', a[13], a[14])
    if a[15]:
        for k in range(a[15]):
            p = m.words(a[16])[9 * k:9 * k + 9]
            print('  position write: register %#06x (%dB address, %dB data) <- %#x | ((code << %d) & %#x), operation %d, '
                  'hw shift %d, delay %d us' % (p[2], p[0], p[1], p[3], p[7], p[6], p[4], p[5], p[8]))
    show_regs(m, 'init settings', a[17], a[18])
    show_regs(m, 'deinit settings', a[19], a[20])
    print(f'  initial code {a[21]}')
    i = 22
    if a[i]:
        for k in range(a[i]):
            r = m.words(a[i + 1])[4 * k:4 * k + 4]
            cps = struct.unpack('<f', struct.pack('<I', r[2] & 0xffffffff))[0]
            print('  region %d: macro step boundary %d, infinity step boundary %d, code per step %g, q value %d' % (
                k, r[0], r[1], cps, r[3]))
    i += 2
    n = 0
    while i + 2 < len(a):
        steps, count, sid = a[i], a[i + 1], a[i + 2]
        if count and sid in m.syms:
            for c, s in zip(m.words(sid)[0::2], m.words(sid)[1::2]):
                r = m.words(s) if s in m.syms else ()
                print('  ringing scenario %d (%d steps): step boundary %d, damping step %d, damping delay/param %#x' % (
                    n, steps, *(r[:3] if len(r) >= 3 else (0, 0, 0))))
        n += 1
        i += 3


def ois(m):
    o = m.top('OISDriver')
    if not o:
        print('OIS: none')
        return
    print('OIS %s: slave %#x (7-bit %#x), I2C %s' % (m.string(o[3], o[4]) if o[3] else '?', o[5], o[5] >> 1,
                                                    I2C.get(o[6], o[6])))
    power(m, 'power-up', o[9], o[10])
    power(m, 'power-down', o[11], o[12])
    # the setting lists that follow: (count, symbol) pairs; a named wrapper holds (count, regSetting)
    unnamed = 0
    for i in range(13, len(o) - 1, 2):
        count, sid = o[i], o[i + 1]
        if sid not in m.syms:
            continue
        name = m.syms[sid][0]
        if name == 'regSetting':
            show_regs(m, f'setting list {unnamed} (init/calibration/enable/disable, in the XSD order)', count, sid)
            unnamed += 1
        elif count:
            inner = m.words(sid)
            show_regs(m, name, inner[0], inner[1])
        else:
            print(f'  {name}: none')


def eeprom(m):
    e = m.top('EEPROMDriverData')
    if not e:
        print('EEPROM: none')
        return
    name = m.string(e[3], e[4]) if e[3] else '?'
    print(f'EEPROM {name}:')
    for i in range(5, len(e) - 1, 2):
        count, sid = e[i], e[i + 1]
        if sid not in m.syms or not count:
            continue
        n = m.syms[sid][0]
        if n == 'powerSetting':
            power(m, 'power', count, sid)
        elif n == 'regSetting':
            rs = m.regsettings(count, sid)
            reads = [r for r in rs if r[5] == 3]
            total = sum(r[2][0] for r in reads)
            print(f'  memory map: {len(rs)} settings, {len(reads)} reads, {total} bytes')
            show_regs(m, 'first settings', count, sid, limit=6)


def flash(m):
    f = m.top('flashDriverData')
    if f and f[3]:
        print(f'flash: {m.string(f[3], f[4])}')


def main():
    args = sys.argv[1:]
    full = args[:1] == ['-a']
    if full:
        args = args[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    m = Module(args[0])
    sensor(m)
    if full:
        module_config(m)
        actuator(m)
        ois(m)
        eeprom(m)
        flash(m)


if __name__ == '__main__':
    main()
