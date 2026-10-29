#!/usr/bin/env python3
"""fakephone.py: a fake sweetmon daemon (the phone side of docs/redfin/sweetmon.md) for testing the collector and the
dashboard without the phone. Python 3 stdlib only.

  fakephone.py [--listen usb=127.0.0.2 --listen wifi=127.0.0.3] [--port 5150] [--key HEX | --key-file F | -K]
               [--trace FILE.swtr] [--trace-lz4 FILE.lz4] [--klog-pa 0x101d0ef08] [--ctl-port 15199]
               [--poke-port 15141] [--klog-dump FILE] [--speedup 1]

Speaks H/S/K/R/T/E/F/P: hello, samples every `rate` ms (process table every TOPEVERY), a fake kernel log ring
(4 MiB, total counter) with SWEET THERMAL/CPUFREQ/BATTERY/GPU/FB lines every 5 s plus chatter, traces (kdebug: the
--trace file, or a small generated SWTRACE1 file; sent as one LZ4 frame in <= 1 MiB T chunks, buffer or stream
mode), pmem (a generated SWPROF1 buffer for the kernel profiler), frames on|off, speed, ping, info, quit.
Kernel profiler pokes ("p prof start NAME HZ SECS", "p prof stop") arrive on UDP --poke-port like the real
command server and print SWEET PROF: start/done lines into the fake log.

Test control (UDP --ctl-port on 127.0.0.1, one word per datagram, answer in the reply datagram):
  drop                 close the client connection
  burst N              write N bytes of filler kernel log now (ring wraps past 4 MiB = lost bytes for the PC)
  down NAME / up NAME  stop / start accepting on the named listener (e.g. usb) to test link switching
  reboot               new boottime + empty log (a new klog file on the PC)
  crash NAME           print a CRASH line;   hot / cool  thermal level 1 / 0 lines;  load N  busy % base
  state                JSON of the fake's state
"""
import argparse
import asyncio
import json
import math
import os
import random
import struct
import sys
import time

RING = 4 << 20
CHUNK = 1 << 20


# ---------------------------------------------------------------- LZ4 frame encoder (greedy, pure python)
def lz4_block(src):
    n = len(src)
    out = bytearray()
    anchor = i = 0
    table = {}
    mflimit = n - 12
    last_lit = n - 5

    def emit(lit_end, mlen, off):
        L = lit_end - anchor
        tok = (min(L, 15) << 4) | (min(mlen - 4, 15) if mlen else 0)
        out.append(tok)
        if L >= 15:
            r = L - 15
            while r >= 255:
                out.append(255)
                r -= 255
            out.append(r)
        out.extend(src[anchor:lit_end])
        if mlen:
            out.extend(struct.pack('<H', off))
            r = mlen - 4
            if r >= 15:
                r -= 15
                while r >= 255:
                    out.append(255)
                    r -= 255
                out.append(r)
    while i < mflimit:
        seq = src[i:i + 4]
        c = table.get(seq)
        table[seq] = i
        if c is not None and i - c < 65536:
            m = 4
            while i + m < last_lit and src[c + m] == src[i + m]:
                m += 1
            emit(i, m, i - c)
            i += m
            anchor = i
        else:
            i += 1
    emit(n, 0, 0)
    return bytes(out)


def lz4_frame_chunks(data, compress=True, bsize=256 << 10):
    """yields the bytes of one LZ4 frame (independent blocks, max block 256 KiB) piece by piece"""
    yield struct.pack('<I', 0x184D2204) + bytes([0x60, 0x50, 0x00])   # v1, independent, BD 256 KiB, HC unchecked
    for p in range(0, len(data), bsize):
        blk = data[p:p + bsize]
        z = lz4_block(blk) if compress else None
        if z is None or len(z) >= len(blk):
            yield struct.pack('<I', 0x80000000 | len(blk)) + blk
        else:
            yield struct.pack('<I', len(z)) + z
    yield struct.pack('<I', 0)


# ---------------------------------------------------------------- generated test files
def make_swtr(nev=4000, secs=2.0):
    """a small valid SWTRACE1 (layout of sweet-trace.py: header 256+ bytes, kd_buf events, thread map)"""
    HDR = struct.Struct('<8sIIIIQQQIIIIIIiIQ128s')
    KD = struct.Struct('<QQQQQQIIQ')
    THR = struct.Struct('<QiI32s64s')
    numer, denom = 125, 3            # 24 MHz timebase -> ns
    start = 10 ** 10
    span = int(secs * 1e9 * denom / numer)
    threads = [(1001, 50, 0, b'backboardd', b'display'), (1002, 50, 0, b'backboardd', b'main'),
               (2001, 60, 0, b'SpringBoard', b'main'), (3001, 70, 0, b'Preferences', b'main'),
               (4001, 80, 0, b'kernel_task', b'')]
    ev = []
    rnd = random.Random(7)
    tids = [t[0] for t in threads]
    sched = (1 << 24) | (0x40 << 16)
    for k in range(nev):
        ts = start + span * k // nev
        cpu = k % 8
        a = rnd.choice(tids)
        ev.append(KD.pack(ts, 0, a, 0, 0, rnd.choice(tids), sched, cpu, 0))
    hs = HDR.size
    end = start + span
    args = b'-t 2 (fakephone)'.ljust(128, b'\0')
    h = HDR.pack(b'SWTRACE1', 1, hs, numer, denom, start, end, len(ev), len(threads), 8, 0, 65536, 3, 0, 1234, 5,
                 int(time.time() * 1e9), args)
    th = b''.join(THR.pack(t, p, f, c.ljust(32, b'\0'), n.ljust(64, b'\0')) for t, p, f, c, n in threads)
    return h + b''.join(ev) + th


def make_prof(name='backboardd', nrec=3000):
    """a small SWPROF1 buffer (sweet-prof.py's load())"""
    text = ('T 1001 display\nT 1002 main\nI 1800000000 /usr/lib/libfake.dylib\n').encode()
    rec0 = 256 + len(text)
    rec0 = (rec0 + 7) & ~7
    recs = bytearray()
    rnd = random.Random(3)
    for k in range(nrec):
        kind = 1 if k % 5 else 2
        depth = 3
        frames = [0x1800001000 + rnd.randrange(0, 0x4000, 4) for _ in range(depth)]
        recs += struct.pack('<QQBBBBIQ', 10 ** 10 + k * 19200, rnd.choice((1001, 1002)), kind, k % 8, depth, 0, 0, 0)
        recs += struct.pack('<%dQ' % depth, *frames)
    keys = ('magic rec0 text_size used start_abs end_abs hz depth wait_hz pid slide sr_base sr_size mh kslide ticks '
            'samples ksamples wsamples dropped xbusy xfail marks tb_num tb_den ncpu overruns name').split()
    vals = dict.fromkeys(keys, 0)
    vals.update(magic=b'SWPROF1\0', rec0=rec0, text_size=len(text), used=len(recs), start_abs=10 ** 10,
                end_abs=10 ** 10 + nrec * 19200, hz=1000, depth=24, pid=50, sr_base=0x180000000, sr_size=0x40000000,
                ticks=nrec, samples=nrec * 4 // 5, ksamples=nrec // 5, tb_num=125, tb_den=3, ncpu=8,
                name=name.encode().ljust(32, b'\0'))
    hdr = struct.pack('<8sIIQQQIIIIQQQQQIIIIIIIIIIII32s', *[vals[k] for k in keys])
    buf = hdr.ljust(256, b'\0') + text
    buf = buf.ljust(rec0, b'\0') + recs
    return bytes(buf)


# ---------------------------------------------------------------- the fake phone
class Phone:
    def __init__(self, a):
        self.a = a
        self.t0 = time.time()
        self.boot = int(time.time()) - 600
        self.up0 = 600.0
        self.klog = bytearray()          # full log since boot (for checking); ring = last 4 MiB
        self.total = 0
        self.dump = open(a.klog_dump, 'wb') if a.klog_dump else None
        self.client = None               # (writer, authed)
        self.rate_ms, self.top_every, self.topn = 1000, 2, 15
        self.klog_on = False
        self.klog_sent = 0
        self.frames = False
        self.trace = None
        self.trace_id = 0
        self.load = 30
        self.level = 0
        self.self_cpu_ms = 0
        self.tx = 0
        self.listeners = {}
        self.down = set()
        self.key = a.key
        if a.key_file:
            self.key = open(a.key_file).read().split()[0]
        self.prof = None
        self.trace_src = open(a.trace, 'rb').read() if a.trace else make_swtr()
        self.trace_lz4 = open(a.trace_lz4, 'rb').read() if a.trace_lz4 else None
        self.prof_buf = make_prof()
        self.prof_pa = 0x129784000
        self.speedup = a.speedup
        self.cmd_log = []
        self.lines_at_boot()

    def up(self):
        return self.up0 + (time.time() - self.t0) * self.speedup

    def kprint(self, msg):
        line = ('[%8.3f] %s\n' % (self.up(), msg)).encode()
        self.klog += line
        self.total += len(line)
        if len(self.klog) > 64 << 20:
            del self.klog[:len(self.klog) - RING]
        if self.dump:
            self.dump.write(line)
            self.dump.flush()

    def ring_bytes(self, pos):
        """bytes from ring position pos to total (pos must be >= total - RING)"""
        start_in_klog = len(self.klog) - (self.total - pos)
        return bytes(self.klog[start_in_klog:])

    def lines_at_boot(self):
        self.kprint('Darwin Kernel Version 22.6.0: fakephone; rorya:xnu-8796.141.3')
        self.kprint('SWEET BATTERY: SPMI arb=0x50010000 APIDs=512, observer reads only')
        for i in range(30):
            self.kprint('SWEET MOTION: boot line %d' % i)

    # -------------------------------------------------------------- periodic kernel log
    async def klog_gen(self):
        n = 0
        while True:
            await asyncio.sleep(5 / self.speedup)
            n += 1
            rnd = random
            base = self.load
            t = 45 + base * 0.35 + 3 * math.sin(n / 7)
            vals = [t + rnd.uniform(-1, 1), t + 3, t + 2.5, t, t - 6, t - 5, t - 4, t - 8, t - 2]
            self.kprint('SWEET THERMAL: silver %.1f gold %.1f prime %.1f cpuss %.1f gpu %.1f ddr %.1f cam %.1f '
                        'npu %.1f aoss %.1f C' % tuple(vals))
            busy = [max(0, min(100, int(base + rnd.uniform(-15, 15) - i * 3))) for i in range(8)]
            mhz = (1804 if base > 40 else 1516, 2208 if base > 40 else 1497, 2400 if base > 40 else 1612)
            self.kprint('SWEET CPUFREQ: busy %d %d %d %d %d %d | %d | %d %%; silver 8=%d MHz (cyc 729, lmh 0) gold '
                        '7=%d MHz (cyc 173, lmh 0) prime 7=%d MHz (cyc 163, lmh 0); gov on 21/39/46 changes; idle off: '
                        'pc 0 resumed 0 early 0, bc 0/0, err 0' % (tuple(busy) + mhz))
            pct = max(1, 80 - n // 20)
            ma = -int(300 + base * 8 + rnd.uniform(0, 60))
            self.kprint('SWEET BATTERY: %dmV %dmA (burst %d) ocv 3889 est %d%% count %d%% (720 mAh) shown %d%% ext=1 '
                        'chg=0 hw=3 temp 2500' % (3600 + pct * 6, ma, ma - 100, pct, pct, pct))
            gms = int(base * 12)
            self.kprint('SWEET GPU: 5s: %d submits (0 missed), GPU busy %d ms (%d%%), longest 18826 us, mean 5654 us; '
                        'backboardd %d/%dms present %d/%dms SpringBoard 3/%dms' %
                        (gms // 6 + 5, gms, gms // 50, gms // 12, int(gms * .7), gms // 15, int(gms * .2), gms // 10))
            self.kprint('SWEET FB: 5s: swaps %d shown %d dropped 1 | le11 0 le18 1 le26 0 le35 0 gt35 1 | p50 11.1 '
                        'p95 33.0 ms | blitq 67116 us fence 3467 us | hz 90 | vis 41425 us cpu 0 us gpuwait 0 us late 0'
                        % (base * 3, base * 3 - 1))
            if n % 3 == 0:
                self.kprint('SWEET GOV: 5s: boosts 1 capped 326 | gold 1728:4968 ms | prime 1766:4968 ms')

    async def chatter(self):
        tags = ('apple80211: wifid sets 383 (?), value 0, 4104 bytes: answered', 'SWEET MOTION: accel 0.01 0.02 0.98',
                'SWEET USB: rx 1514 tx 66', 'adsp: glink rx 32 bytes', 'SWEET HID: touch 540 1200 down')
        while True:
            await asyncio.sleep(0.2 / self.speedup)
            for _ in range(random.randint(0, 3)):
                self.kprint(random.choice(tags))

    # -------------------------------------------------------------- frames
    def frame(self, t, payload):
        if isinstance(payload, (dict, list)):
            payload = json.dumps(payload, separators=(',', ':')).encode()
        return struct.pack('<IB', len(payload) + 1, ord(t)) + payload

    async def send(self, w, t, payload):
        d = self.frame(t, payload)
        self.tx += len(d)
        w.write(d)
        await w.drain()

    def hello(self):
        return {'v': 1, 'pid': os.getpid(), 'uptime_s': round(self.up(), 1), 'ncpu': 8, 'tb_numer': 125,
                'tb_denom': 3, 'boottime': self.boot, 'ifaces': {'en0': self.a.wifi_addr, 'en2': '192.168.7.2'},
                'klog_pa': self.a.hello_pa, 'version': 'fakephone-1'}

    async def handle(self, r, w, lname):
        authed = not self.key
        writer_ref = {'w': w, 'authed': authed, 'tasks': [], 'lname': lname}
        await self.send(w, 'H', self.hello())
        try:
            while True:
                h = await r.readexactly(5)
                n, t = struct.unpack('<IB', h)
                if n < 1 or n > (4 << 20):
                    break
                p = await r.readexactly(n - 1)
                if chr(t) != 'C':
                    continue
                line = p.decode(errors='replace').strip()
                self.cmd_log.append((lname, line.split()[0] if line else ''))
                word = line.split()[0] if line else ''
                if not writer_ref['authed']:
                    if word == 'auth' and line.split()[1:2] == [self.key]:
                        writer_ref['authed'] = True
                        old = self.client
                        self.client = writer_ref
                        if old and old['w'] is not w:
                            old['w'].close()
                        await self.send(w, 'R', {'cmd': 'auth', 'ok': True, 'msg': 'ok'})
                        writer_ref['tasks'].append(asyncio.ensure_future(self.sampler(writer_ref)))
                    else:
                        await self.send(w, 'R', {'cmd': word, 'ok': False, 'msg': 'auth first'})
                    continue
                if self.client is not writer_ref:
                    self.client = writer_ref
                    writer_ref['tasks'].append(asyncio.ensure_future(self.sampler(writer_ref)))
                await self.command(writer_ref, line)
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        finally:
            for tk in writer_ref['tasks']:
                tk.cancel()
            if self.client is writer_ref:
                self.client = None
                self.klog_on = False
            w.close()

    async def command(self, c, line):
        w = c['w']
        a = line.split()
        word = a[0] if a else ''
        R = lambda ok, msg='', **k: self.send(w, 'R', dict({'cmd': word, 'ok': ok, 'msg': msg}, **k))
        if word == 'auth':
            await R(True, 'ok')
        elif word == 'rate':
            self.rate_ms = max(200, min(int(a[1]), 10000)) if len(a) > 1 else 1000
            self.top_every = int(a[2]) if len(a) > 2 else 2
            await R(True, 'rate %d %d' % (self.rate_ms, self.top_every))
        elif word == 'top':
            self.topn = int(a[1])
            await R(True, 'top %d' % self.topn)
        elif word == 'klog':
            if len(a) > 1 and a[1] == 'off':
                self.klog_on = False
                await R(True, 'off')
            elif len(a) > 2 and a[1] == 'from':
                pos = int(a[2])
                if pos < self.total - RING:
                    await R(False, 'position %d no longer in the ring (oldest %d)' % (pos, self.total - RING))
                elif not self.klog_on:
                    await R(False, 'klog not started')
                else:
                    await R(True, 'resend from %d (%d bytes)' % (pos, self.total - pos))
                    await self.send_klog(w, pos)
            elif len(a) > 1:
                if int(a[1], 16) != int(self.a.klog_pa, 16):
                    await R(False, 'no printable text in the last 4 KiB of the ring at %s' % a[1])
                else:
                    await R(True, 'tailing %s, total %d' % (a[1], self.total))
                    self.klog_on = True
                    await self.send_klog(w, max(0, self.total - RING))
            else:
                await R(False, 'klog PA | off | from POS')
        elif word == 'trace':
            await self.trace_cmd(c, a, R)
        elif word == 'pmem':
            if len(a) < 3:
                await R(False, 'pmem PA LEN [id]')
                return
            pa, ln = int(a[1], 16), int(a[2], 0)
            tid = int(a[3]) if len(a) > 3 else 900
            if ln > 64 << 20:
                await R(False, 'LEN <= 64 MiB')
                return
            off = pa - self.prof_pa
            if off < 0 or off >= 8 << 20:
                data = bytes(ln)
            else:
                data = (self.prof_buf + bytes(max(0, off + ln - len(self.prof_buf))))[off:off + ln]
            await R(True, 'pmem %d bytes' % ln, id=tid)
            asyncio.ensure_future(self.send_trace(w, tid, data, 'pmem', 0.1, {}))
        elif word == 'frames':
            self.frames = len(a) > 1 and a[1] == 'on'
            await R(True, 'frames %s' % ('on' if self.frames else 'off'))
        elif word == 'speed':
            mb = int(a[1]) if len(a) > 1 else 16
            blk = os.urandom(CHUNK)
            t0 = time.time()
            for _ in range(mb):
                await self.send(w, 'P', blk)
            await R(True, 'sent %d MiB' % mb, secs=round(time.time() - t0, 3), cpu_ms=int(mb * 4))
        elif word == 'ping':
            await R(True, ' '.join(a[1:]))
        elif word == 'info':
            await R(True, 'fakephone', build='fakephone-1', rate_ms=self.rate_ms, kdebug_owner=None,
                    rss_kb=2048, klog_total=self.total)
        elif word == 'quit':
            await R(True, 'bye')
            w.close()
        else:
            await R(False, 'unknown command %s' % word)

    async def send_klog(self, w, pos):
        data = self.ring_bytes(pos)
        for p in range(0, len(data), 256 << 10):
            await self.send(w, 'K', struct.pack('<Q', pos + p) + data[p:p + (256 << 10)])
        self.klog_sent = self.total

    async def trace_cmd(self, c, a, R):
        w = c['w']
        sub = a[1] if len(a) > 1 else ''
        if sub == 'start':
            if self.trace:
                await R(False, 'a trace runs (id %d)' % self.trace['id'])
                return
            kv = dict(x.split('=', 1) for x in a[3:] if '=' in x)
            secs = min(int(kv.get('secs', 60)), 600)
            self.trace_id += 1
            ev = asyncio.Event()
            self.trace = {'id': self.trace_id, 'secs': secs, 'mode': kv.get('mode', 'buffer'), 'stop': ev,
                          'opts': kv, 't0': time.time()}
            await R(True, 'tracing %d s (%s)' % (secs, self.trace['mode']), id=self.trace_id)
            asyncio.ensure_future(self.trace_run(w, self.trace))
        elif sub in ('stop', 'abort'):
            if not self.trace:
                await R(False, 'no trace')
                return
            self.trace['abort'] = sub == 'abort'
            self.trace['stop'].set()
            await R(True, sub)
        else:
            await R(False, 'trace start kdebug [k=v ...] | stop | abort')

    async def trace_run(self, w, tr):
        try:
            if tr['mode'] == 'stream':
                # stream: chunks while recording (the frame is produced up front, paced over the trace's time)
                z = self.trace_lz4 or b''.join(lz4_frame_chunks(self.trace_src, len(self.trace_src) <= self.a.compress_max))
                n = max(1, math.ceil(len(z) / CHUNK))
                seq = 0
                for i in range(n):
                    if tr['stop'].is_set():
                        break
                    await self.send(w, 'T', struct.pack('<II', tr['id'], seq) + z[i * CHUNK:(i + 1) * CHUNK])
                    seq += 1
                    try:
                        await asyncio.wait_for(tr['stop'].wait(), tr['secs'] / n / self.speedup)
                    except asyncio.TimeoutError:
                        pass
                if tr.get('abort'):
                    return
                for i in range(seq, n):
                    await self.send(w, 'T', struct.pack('<II', tr['id'], i) + z[i * CHUNK:(i + 1) * CHUNK])
                await self.send(w, 'E', self.end_json(tr, len(self.trace_src), len(z), 'kdebug'))
                return
            try:
                await asyncio.wait_for(tr['stop'].wait(), tr['secs'] / self.speedup)
            except asyncio.TimeoutError:
                pass
            if tr.get('abort'):
                return
            await self.send_trace(w, tr['id'], self.trace_src, 'kdebug', time.time() - tr['t0'], tr, pre=self.trace_lz4)
        except (ConnectionError, OSError):
            pass
        finally:
            if self.trace is tr:
                self.trace = None

    def end_json(self, tr, nbytes, zbytes, kind):
        return {'id': tr['id'] if isinstance(tr, dict) and 'id' in tr else tr, 'kind': kind, 'bytes': nbytes,
                'zbytes': zbytes, 'events': nbytes // 64, 'threads': 5, 'wrapped': False, 'lost': 0,
                'secs': round(time.time() - tr['t0'], 2) if isinstance(tr, dict) and 't0' in tr else 0.1,
                'cpu_ms': 42}

    async def send_trace(self, w, tid, data, kind, secs, tr, pre=None):
        if pre is not None:
            pieces = [pre]
        else:
            pieces = lz4_frame_chunks(data, len(data) <= self.a.compress_max)
        buf = bytearray()
        seq = 0
        zb = 0
        for piece in pieces:
            buf += piece
            while len(buf) >= CHUNK:
                await self.send(w, 'T', struct.pack('<II', tid, seq) + bytes(buf[:CHUNK]))
                zb += CHUNK
                del buf[:CHUNK]
                seq += 1
        if buf:
            await self.send(w, 'T', struct.pack('<II', tid, seq) + bytes(buf))
            zb += len(buf)
        e = {'id': tid, 'kind': kind, 'bytes': len(data), 'zbytes': zb, 'events': len(data) // 64, 'threads': 5,
             'wrapped': False, 'lost': 0, 'secs': round(secs, 2), 'cpu_ms': 42}
        await self.send(w, 'E', e)

    # -------------------------------------------------------------- samples
    async def sampler(self, c):
        w = c['w']
        n = 0
        last = time.time()
        procs = [(50, 'backboardd'), (60, 'SpringBoard'), (70, 'Preferences'), (81, 'wifid'), (90, 'configd'),
                 (95, 'mediaserverd'), (101, 'locationd'), (110, 'sweetmon'), (120, 'launchd'), (130, 'logd'),
                 (140, 'bluetoothd'), (150, 'thermalmonitord'), (160, 'symptomsd'), (170, 'runningboardd'),
                 (180, 'sharingd'), (190, 'nsurlsessiond'), (200, 'cfprefsd')]
        try:
            while True:
                await asyncio.sleep(self.rate_ms / 1000 / self.speedup)
                now = time.time()
                dt_ms = int((now - last) * 1000)
                last = now
                n += 1
                ticks = max(1, int(dt_ms / 10))
                cpu = []
                for i in range(8):
                    b = max(0, min(100, self.load + random.uniform(-20, 20) - i * 3)) / 100
                    u = int(ticks * b * 0.7)
                    s = int(ticks * b * 0.3)
                    cpu.append([u, s, ticks - u - s, 0])
                t = 45 + self.load * 0.35
                s = {'t': int(self.up() * 1e9), 'up': round(self.up(), 2), 'dt_ms': dt_ms, 'cpu': cpu,
                     'temp': {'silver': int(t * 10), 'gold': int(t * 10 + 30), 'prime': int(t * 10 + 25),
                              'cpuss': int(t * 10), 'gpu': int(t * 10 - 60), 'ddr': int(t * 10 - 50),
                              'camera': int(t * 10 - 40), 'npu': int(t * 10 - 80), 'aoss': int(t * 10 - 20),
                              'max': int(t * 10 + 30)},
                     'vm': {'free': 180000 + random.randint(-2000, 2000), 'active': 120000, 'inactive': 60000,
                            'wired': 90000, 'compressed': 4000, 'spec': 3000, 'pageins': random.randint(0, 30),
                            'swapins': 0, 'faults': random.randint(1000, 5000), 'page_kb': 16},
                     'load': [round(self.load / 25, 2), 1.2, 1.0], 'nproc': 87,
                     'self': {'cpu_ms': random.randint(2, 9) * dt_ms // 1000, 'rss_kb': 2400,
                              'klog_bps': 900, 'tx_bps': 3000},
                     'klog_bps': 1500 + self.load * 20}
                if self.top_every and n % self.top_every == 0 and self.topn:
                    rows = []
                    for pid, name in procs:
                        w8 = {'backboardd': 4, 'SpringBoard': 2, 'Preferences': 1.5, 'sweetmon': 0.05}.get(name, 0.3)
                        cpu_ms = int(w8 * self.load * random.uniform(0.5, 1.5) * dt_ms * self.top_every / 1000)
                        rows.append([pid, name, cpu_ms, random.randint(0, 400 if name == 'wifid' else 60) *
                                     self.top_every, random.randint(2000, 90000), random.randint(3, 40),
                                     random.randint(0, 50)])
                    rows.sort(key=lambda r: -r[2])
                    s['procs'] = rows[:self.topn]
                await self.send(w, 'S', s)
                if self.frames and not self.trace:
                    await self.send(w, 'F', {'t': s['t'], 'frames': 80, 'fps': round(60 + random.uniform(-15, 25), 1),
                                             'vsync': 90, 'gpu_ms_p50': 6.1, 'gpu_ms_p90': 9.8,
                                             'present_to_shown_ms_p50': 11.2})
        except (ConnectionError, OSError):
            pass

    async def klog_push(self):
        # 250 ms klog poll like the daemon (the sampler also flushes)
        while True:
            await asyncio.sleep(0.25)
            c = self.client
            if c and c['authed'] and self.klog_on and self.total > self.klog_sent:
                try:
                    await self.send_klog(c['w'], self.klog_sent)
                except (ConnectionError, OSError):
                    pass

    # -------------------------------------------------------------- pokes (kernel profiler) and test control
    class Udp(asyncio.DatagramProtocol):
        def __init__(self, fn):
            self.fn = fn

        def connection_made(self, tr):
            self.tr = tr

        def datagram_received(self, d, addr):
            r = self.fn(d.decode(errors='replace').strip())
            if r is not None:
                self.tr.sendto(r.encode(), addr)

    def poke(self, text):
        a = text.split()
        if a[:3] == ['p', 'prof', 'start'] and len(a) >= 4:
            if self.prof:
                self.kprint('SWEET PROF: busy (p prof stop first)')
                return None
            hz = int(a[4]) if len(a) > 4 else 1000
            secs = int(a[5]) if len(a) > 5 else 10
            self.prof = {'name': a[3], 'hz': hz, 'secs': secs, 'ev': asyncio.Event()}
            self.kprint('SWEET PROF: start %s[50] %d Hz %d s depth 24 wait 0 Hz, 25 threads, buffer 8192 KiB at pa 0x%x'
                        % (a[3], hz, secs, self.prof_pa))
            asyncio.ensure_future(self.prof_run(self.prof))
        elif a[:3] == ['p', 'prof', 'stop']:
            if self.prof:
                self.prof['ev'].set()
            else:
                self.kprint('SWEET PROF: nothing to stop')
        else:
            self.kprint('POKE: %s' % text[:80])
        return None

    async def prof_run(self, p):
        t0 = time.time()
        try:
            await asyncio.wait_for(p['ev'].wait(), p['secs'] / self.speedup)
        except asyncio.TimeoutError:
            pass
        ms = int((time.time() - t0) * 1000)
        self.kprint('SWEET PROF: done %s[50] %d ms at %d Hz depth 24 wait 0 Hz: 2400 user + 600 kernel + 0 off-CPU '
                    'samples, 0 marks, 3000 ticks (0 late), 0 dropped, xcall busy 0 fail 0 | pa 0x%x bytes %d (agent: '
                    'files read /dev/pmem 0x%x %d ...)' % (p['name'], ms, p['hz'], self.prof_pa, len(self.prof_buf),
                                                            self.prof_pa, len(self.prof_buf)))
        self.prof = None

    def control(self, text):
        a = text.split()
        if not a:
            return 'empty'
        c = a[0]
        if c == 'drop':
            if self.client:
                self.client['w'].close()
                return 'dropped'
            return 'no client'
        if c == 'burst':
            n = int(a[1])
            k = 0
            while k < n:
                self.kprint('SWEET BURST: ' + 'x' * 100)
                k += 114
            return 'burst %d total %d' % (n, self.total)
        if c in ('down', 'up'):
            (self.down.add if c == 'down' else self.down.discard)(a[1])
            if c == 'down' and self.client and self.client.get('lname') == a[1]:
                self.client['w'].close()
            return '%s %s' % (c, a[1])
        if c == 'reboot':
            self.boot = int(time.time())
            self.t0 = time.time()
            self.up0 = 0.0
            self.klog = bytearray()
            self.total = 0
            self.klog_sent = 0
            self.lines_at_boot()
            if self.client:
                self.client['w'].close()
            return 'rebooted boottime %d' % self.boot
        if c == 'crash':
            self.kprint('CRASH %s[%d] sig 11 code 0x0 sub 0x0 slide 0x436cc000 mh 0x102bf4000' %
                        (a[1] if len(a) > 1 else 'fakeapp', random.randint(100, 999)))
            return 'crash'
        if c == 'hot':
            self.level = 1
            self.kprint('SWEET THERMAL: level 0 -> 1 (hot 75.3 C): silver 0 gold 1800 prime 1800 MHz cap, gpu 0')
            return 'hot'
        if c == 'cool':
            self.level = 0
            self.kprint('SWEET THERMAL: level 1 -> 0 (hot 64.7 C): silver 0 gold 0 prime 0 MHz cap, gpu 0')
            return 'cool'
        if c == 'load':
            self.load = int(a[1])
            return 'load %d' % self.load
        if c == 'state':
            return json.dumps({'total': self.total, 'boot': self.boot, 'client': bool(self.client),
                               'klog_on': self.klog_on, 'down': sorted(self.down), 'trace': bool(self.trace),
                               'cmds': self.cmd_log[-40:], 'tx': self.tx})
        return 'unknown'

    async def serve(self):
        loop = asyncio.get_running_loop()
        for spec in self.a.listen:
            name, _, host = spec.partition('=')

            def mk(nm):
                async def cb(r, w):
                    if nm in self.down:
                        w.close()
                        return
                    await self.handle(r, w, nm)
                return cb
            self.listeners[name] = await asyncio.start_server(mk(name), host, self.a.port)
        await loop.create_datagram_endpoint(lambda: self.Udp(self.control), local_addr=('127.0.0.1', self.a.ctl_port))
        await loop.create_datagram_endpoint(lambda: self.Udp(self.poke), local_addr=(self.a.poke_host, self.a.poke_port))
        print('fakephone pid %d: %s port %d, ctl udp %d, poke udp %s:%d' % (os.getpid(), self.a.listen, self.a.port,
                                                                           self.a.ctl_port, self.a.poke_host,
                                                                           self.a.poke_port), flush=True)
        await asyncio.gather(self.klog_gen(), self.chatter(), self.klog_push())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--listen', action='append', help='NAME=ADDR (default usb=127.0.0.2, wifi=127.0.0.3)')
    ap.add_argument('--port', type=int, default=5150)
    ap.add_argument('--wifi-addr', default='127.0.0.3', help='en0 address in the hello')
    ap.add_argument('--key')
    ap.add_argument('--key-file')
    ap.add_argument('-K', action='store_true', help='no auth')
    ap.add_argument('--trace')
    ap.add_argument('--trace-lz4', help='send this ready LZ4 frame as the trace data (e.g. made by the real lz4.c)')
    ap.add_argument('--compress-max', type=int, default=8 << 20, help='compress traces up to this size, raw blocks above')
    ap.add_argument('--klog-pa', default='0x101d0ef08')
    ap.add_argument('--hello-pa', default=None, help='klog_pa in the hello (default null, as the daemon may send)')
    ap.add_argument('--klog-dump')
    ap.add_argument('--ctl-port', type=int, default=15199)
    ap.add_argument('--poke-host', default='127.0.0.2')
    ap.add_argument('--poke-port', type=int, default=15141)
    ap.add_argument('--speedup', type=float, default=1.0, help='time runs this much faster for the log/samples')
    ap.add_argument('--gen-swtr', metavar='OUT', help='write the generated small .swtr and exit')
    a = ap.parse_args()
    if a.gen_swtr:
        open(a.gen_swtr, 'wb').write(make_swtr())
        return 0
    a.listen = a.listen or ['usb=127.0.0.2', 'wifi=127.0.0.3']
    if a.K:
        a.key = None
    elif not a.key and not a.key_file:
        sys.exit('fakephone: --key HEX, --key-file FILE or -K (like the daemon: no key file = refuse to start)')
    try:
        asyncio.run(Phone(a).serve())
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    sys.exit(main() or 0)
