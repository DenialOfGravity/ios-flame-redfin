#!/usr/bin/env python3
"""Make a camera sensor's register tables for the kernel (bsd/dev/sweet_cam.c, "poke c 21 N [MODE]") out of
the sensor's module file of the Pixel 5's camera stack (/vendor/lib64/camera/com.qti.sensormodule.*_lito2.bin,
pulled read-only by the phone agent's twrp-pull-camera into recon/camera). The module files and what this
makes of them are the vendor's: they stay out of git. The table goes onto the phone as
/private/var/local/fw/camera-<sensor>.tab (phone agent: files put).

  tools/redfin-camtab.py MODULE.bin OUT.tab     (OUT "-": list only)

The module file: "QTI Chromatix Header", "Parameter Parser V2.0.0" (tools/redfin-camsensor.py has the
layout). Every value is a u64; arrays are (count, symbol id) pairs. A resolution element (resolutionData) is
37 words:
  [0] colour filter (CamX: 0 BGGR, 1 GBRG, 2 GRBG, 3 RGGB, 4 mono)  [1],[2] stream configurations
  [3] line length (pixel clocks)  [4] frame length (lines)  [7] output pixel clock  [8],[9] binning
  [10] frames a second (double)  [11] lanes  [12],[13] down-scale factors  [14] CSIPHY settle count
  [15] C-PHY  [16],[17] integration info  [18],[19] the mode's register settings
A stream configuration is 8 words { vc, dt, x, y, width, height, bits a pixel, type }. A register setting is
10 words { slave present, slave, address, data count, data, address type, data type, operation, delay
present, delay } (address/data type 1 byte, 2 word; operation 0 write). The sensor driver's other register
settings come in its XML's order: after "regToRealGain" stream on, stream off, group hold on, group hold off;
after "initSettings" the initialisation; after "testPatternData" one table a pattern (0 off, then the
patterns).

OUT.tab ("RFCTAB01", all little-endian u32 unless said):
  magic[8], slave (7-bit), lane assignment, modes, tables
  modes x { width, height, x, y, lanes, cphy, settle, pixel clock, line length, frame length, fps x 1000,
            data type, colour filter, table index }
  tables x { name[8], count, count x { address u16, data u16, address bytes u8, data bytes u8,
             operation u8, 0 u8, delay in us } }
The modes' own tables are res0, res1, ...; the others init, on, off, holdon, holdoff, tpg0, tpg1, ...
"""
import struct
import sys


def load(path):
    d = open(path, 'rb').read()
    if not d.startswith(b'QTI Chromatix Header') or b'Parameter Parser V2.0.0' not in d[:0x60]:
        sys.exit(f'{path}: not a V2 CamX module file')
    toff, tsz = struct.unpack_from('<QQ', d, 0xa8)
    doff, dsz = struct.unpack_from('<QQ', d, 0xc0)
    syms, order = {}, []
    for o in range(toff, toff + tsz, 0x48):
        sid, name, kind, parent, off, size = struct.unpack_from('<Q32sQQQQ', d, o)
        syms[sid] = (name.split(b'\0')[0].decode('latin1'), off, size)
        order.append(sid)
    return d[doff:doff + dsz], syms, order


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data, syms, order = load(sys.argv[1])

    def words(sid):
        _, off, size = syms[sid]
        return struct.unpack_from('<%dQ' % (size // 8), data, off)

    def regsetting(sid):
        out = []
        _, off, size = syms[sid]
        for e in range(off, off + size, 80):
            _, _, addr, count, dsid, atype, dtype, op, has_delay, delay_sid = struct.unpack_from('<10Q', data, e)
            vals = words(dsid)[:max(count, 1)] if dsid in syms else (0,)
            delay = words(delay_sid)[0] if has_delay and delay_sid in syms and syms[delay_sid][2] >= 8 else 0
            for i, v in enumerate(vals):
                # a burst (count > 1) writes the next addresses
                out.append((addr + i * dtype, v, atype, dtype, op, delay if i == len(vals) - 1 else 0))
        return out

    driver = words(1)
    slave = driver[5] >> 1
    rsid = next(s for s in order if syms[s][0] == 'resolutionData')
    raw = words(rsid)
    modes, tables, mode_sids = [], [], set()
    for k in range(len(raw) // 37):
        w = raw[37 * k:37 * k + 37]
        fps = struct.unpack('<d', struct.pack('<Q', w[10]))[0]
        sc = words(w[2])[:8]
        vc, dt, x, y, width, height = sc[:6]
        modes.append([width, height, x, y, w[11], w[15], w[14], w[7], w[3], w[4], int(round(fps * 1000)), dt, w[0], 0])
        mode_sids.add(w[19])
        tables.append(('res%d' % k, regsetting(w[19])))
        modes[-1][13] = len(tables) - 1
    lane = next((s for s in order if syms[s][0] == 'laneAssign'), None)
    lane_assign = words(lane)[0] & 0xffff if lane is not None and syms[lane][2] >= 8 else 0x3210
    roles = {'regToRealGain': ['on', 'off', 'holdon', 'holdoff'], 'initSettings': ['init']}
    after, used = '', {}
    for sid in order:
        name = syms[sid][0]
        if name != 'regSetting':
            if name not in ('slaveAddr', 'registerData', 'delayUs', '[0]'):
                after = name
            continue
        if sid in mode_sids or syms[sid][2] == 0:
            continue
        n = used.get(after, 0)
        used[after] = n + 1
        if after == 'testPatternData':
            tables.append(('tpg%d' % n, regsetting(sid)))
        elif n < len(roles.get(after, [])):
            tables.append((roles[after][n], regsetting(sid)))
        # (the EEPROM's and others' settings are not the sensor's)

    print(f'{sys.argv[1]}: slave {slave:#x}, lane assignment {lane_assign:#x}')
    cfa = {0: 'BGGR', 1: 'GBRG', 2: 'GRBG', 3: 'RGGB', 4: 'mono'}
    for k, m in enumerate(modes):
        print(f'  mode {k}: {m[0]}x{m[1]} at {m[2]},{m[3]} dt {m[11]:#x}, {m[4]} {"trios" if m[5] else "lanes"}, settle {m[6]}, '
              f'pixel clock {m[7]}, line {m[8]}, frame {m[9]}, {m[10] / 1000:.3f} fps, {cfa.get(m[12], m[12])}')
    for name, t in tables:
        print(f'  {name}: {len(t)} writes: ' + ' '.join(f'{a:x}={v:x}' + (f'+{d}us' if d else '') for a, v, _, _, _, d in t[:8]) +
              (' ...' if len(t) > 8 else ''))
    if sys.argv[2] == '-':
        return
    out = bytearray(b'RFCTAB01') + struct.pack('<4I', slave, lane_assign, len(modes), len(tables))
    for m in modes:
        out += struct.pack('<14I', *m)
    for name, t in tables:
        out += name.encode().ljust(8, b'\0')[:8] + struct.pack('<I', len(t))
        for a, v, ab, db, op, dl in t:
            out += struct.pack('<HHBBBBI', a, v, ab, db, op, 0, dl)
    open(sys.argv[2], 'wb').write(out)
    print(f'{sys.argv[2]}: {len(out)} bytes')


main()
