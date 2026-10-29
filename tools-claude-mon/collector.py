#!/usr/bin/env python3
"""sweetmon collector (PC/WSL side): keeps one connection to the phone's sweetmon daemon (TCP 5150, USB or Wi-Fi),
stores everything on disk and serves the live dashboard + JSON API on http://127.0.0.1:8765/.
Protocol and design: docs/redfin/sweetmon.md (branch ws-z-mon). Python 3 stdlib only (uses the `lz4` module or the
`lz4` binary when present, else its own pure-python LZ4 frame decoder).

  collector.py [--root DIR] [--link auto|usb|wifi] [--http-host 127.0.0.1] [--http-port 8765]
  collector.py --make-key [--force]          agent/sweetmon.key (one hex line; the phone gets it via `mon install`)
  collector.py ctl CMD ...                   client for the phone agent's `mon ...` actions (talks to the API):
      status | snap | trace NAME [kdebug|prof] [SECS] [k=v ...] | stop | traces | wait [SECS] | link usb|wifi|auto
      | speed [MB] | frames on|off | klog-pa PA | cmd TEXT

Files (under --root, default /mnt/c/ClaudeProjects/iOS_Pixel5):
  logs/mon/now.json             latest merged snapshot (rewritten atomically every sample)
  logs/mon/metrics-YYYYMMDD.jsonl  one compact line per sample
  logs/mon/klog-<boottime>.txt  the full kernel log of that boot (gap-filled after reconnects)
  logs/mon/collector.log        this program's log;  logs/mon/config.json, phone.json, state.json
  logs/traces/NAME-MMDD-HHMMSS/ trace.swtr (or prof.bin), meta.json, summary.json, report.txt
"""
import argparse
import asyncio
import collections
import datetime as dt
import json
import logging
import os
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = '/mnt/c/ClaudeProjects/iOS_Pixel5'
USB_HOST = '192.168.7.2'
DEFAULT_KLOG_PA = '0x101d0ef08'     # r63a (builds/xnu/ws-y-ram-aca60f47b8/KLOG_PA.txt)
PORT = 5150
MAX_FRAME = 4 << 20
CLUSTERS = (('silver', range(0, 6)), ('gold', range(6, 7)), ('prime', range(7, 8)))
TEMP_KEYS = ('silver', 'gold', 'prime', 'cpuss', 'gpu', 'ddr', 'camera', 'npu', 'aoss')
log = logging.getLogger('sweetmon')


# ---------------------------------------------------------------- LZ4 frame decoding (streaming)
class LZ4Error(Exception):
    pass


def _lz4_block(src, out):
    """decode one LZ4 block from bytes src, appending to bytearray out (out's prefix is the dictionary)"""
    i, n = 0, len(src)
    while i < n:
        t = src[i]
        i += 1
        ln = t >> 4
        if ln == 15:
            while True:
                b = src[i]
                i += 1
                ln += b
                if b != 255:
                    break
        if ln:
            out += src[i:i + ln]
            i += ln
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8)
        i += 2
        m = t & 15
        if m == 15:
            while True:
                b = src[i]
                i += 1
                m += b
                if b != 255:
                    break
        m += 4
        s = len(out) - off
        if off == 0 or s < 0:
            raise LZ4Error('bad match offset %d' % off)
        if off >= m:
            out += out[s:s + m]
        else:
            pat = bytes(out[s:])
            q, r = divmod(m, off)
            out += pat * q + pat[:r]


class LZ4FrameDecoder:
    """feed(bytes) -> decoded bytes; handles concatenated frames, linked/independent blocks, raw blocks, checksums,
    content size, dict id and skippable frames"""

    def __init__(self):
        self.buf = bytearray()
        self.state = 'magic'
        self.win = bytearray()
        self.flg = 0
        self.total = 0
        self.frames = 0
        self.skip = 0

    def feed(self, data):
        self.buf += data
        res = bytearray()
        b = self.buf
        while True:
            if self.state == 'magic':
                if len(b) < 4:
                    break
                mg = struct.unpack_from('<I', b, 0)[0]
                if 0x184D2A50 <= mg <= 0x184D2A5F:
                    if len(b) < 8:
                        break
                    self.skip = struct.unpack_from('<I', b, 4)[0]
                    del b[:8]
                    self.state = 'skip'
                    continue
                if mg != 0x184D2204:
                    raise LZ4Error('not an LZ4 frame (magic 0x%08x)' % mg)
                if len(b) < 7:
                    break
                flg = b[4]
                hl = 7 + (8 if flg & 8 else 0) + (4 if flg & 1 else 0)
                if len(b) < hl:
                    break
                if (flg >> 6) != 1:
                    raise LZ4Error('LZ4 frame version %d' % (flg >> 6))
                self.flg = flg
                self.win = bytearray()
                del b[:hl]
                self.state = 'block'
            elif self.state == 'skip':
                k = min(self.skip, len(b))
                del b[:k]
                self.skip -= k
                if self.skip:
                    break
                self.state = 'magic'
            elif self.state == 'block':
                if len(b) < 4:
                    break
                sz = struct.unpack_from('<I', b, 0)[0]
                if sz == 0:
                    if len(b) < 4 + (4 if self.flg & 4 else 0):
                        break
                    del b[:4 + (4 if self.flg & 4 else 0)]
                    self.frames += 1
                    self.state = 'magic'
                    continue
                raw = sz & 0x80000000
                sz &= 0x7fffffff
                need = 4 + sz + (4 if self.flg & 0x10 else 0)
                if len(b) < need:
                    break
                blk = bytes(b[4:4 + sz])
                del b[:need]
                if raw:
                    o = blk
                else:
                    linked = not (self.flg & 0x20)
                    out = bytearray(self.win) if linked else bytearray()
                    pre = len(out)
                    _lz4_block(blk, out)
                    o = bytes(out[pre:])
                if not (self.flg & 0x20):
                    self.win += o
                    if len(self.win) > 65536:
                        del self.win[:len(self.win) - 65536]
                res += o
                self.total += len(o)
        return bytes(res)

    def done(self):
        return self.state == 'magic' and not self.buf and self.frames > 0


def lz4_decompress_file(src, dst, progress=None):
    """src .lz4 frame file -> dst; returns (bytes, method)"""
    try:
        import lz4.frame as lzf     # noqa
        d = lzf.LZ4FrameDecompressor()
        n = 0
        with open(src, 'rb') as fi, open(dst, 'wb') as fo:
            while True:
                c = fi.read(1 << 20)
                if not c:
                    break
                o = d.decompress(c)
                fo.write(o)
                n += len(o)
        return n, 'lz4 module'
    except ImportError:
        pass
    exe = shutil.which('lz4')
    if exe:
        r = subprocess.run([exe, '-d', '-c', '-q', src], stdout=open(dst, 'wb'), stderr=subprocess.PIPE, timeout=600)
        if r.returncode == 0:
            return os.path.getsize(dst), 'lz4 binary'
        log.warning('lz4 binary failed (%s): pure python instead', r.stderr.decode(errors='replace').strip()[:200])
    d = LZ4FrameDecoder()
    n = 0
    with open(src, 'rb') as fi, open(dst, 'wb') as fo:
        while True:
            c = fi.read(1 << 20)
            if not c:
                break
            o = d.feed(c)
            fo.write(o)
            n += len(o)
            if progress:
                progress(n)
    if not d.done():
        raise LZ4Error('truncated LZ4 frame (%d bytes decoded)' % n)
    return n, 'pure python'


def lz4_decompress_any(src, dst):
    """the streaming decoder above; on a format error, the repo's tools/lz4py.py (shipped next to this file) as a
    second opinion"""
    try:
        return lz4_decompress_file(src, dst)
    except (LZ4Error, IndexError, struct.error) as e:
        try:
            if HERE not in sys.path:
                sys.path.insert(0, HERE)
            import lz4py
        except ImportError:
            raise e
        log.warning('LZ4 decoder: %s; trying lz4py.py', e)
        data = lz4py.decompress(open(src, 'rb').read())
        with open(dst, 'wb') as f:
            f.write(data)
        return len(data), 'lz4py.py'


# ---------------------------------------------------------------- klog parsing
R_TS = re.compile(r'^\[\s*(\d+\.\d+)\]\s?(.*)$')
R_TEMP = re.compile(r'SWEET THERMAL: silver ([\d.]+) gold ([\d.]+) prime ([\d.]+) cpuss ([\d.]+) gpu ([\d.]+) '
                    r'ddr ([\d.]+) cam ([\d.]+) npu ([\d.]+) aoss ([\d.]+) C')
R_LEVEL = re.compile(r'SWEET THERMAL: level (\d+) -> (\d+) \(hot ([\d.]+) C\): silver (\d+) gold (\d+) prime (\d+) '
                     r'MHz cap, gpu (\d+)')
R_CPUF = re.compile(r'SWEET CPUFREQ: busy ([\d ]+)\|([\d ]+)\|([\d ]+)%; silver (\d+)=(\d+) MHz.*?gold (\d+)=(\d+) MHz'
                    r'.*?prime (\d+)=(\d+) MHz')
R_BAT = re.compile(r'SWEET BATTERY: (\d+)mV (-?\d+)mA.*?shown (\d+)% ext=(\d) chg=(\d)(?:.*?temp (-?\d+))?')
R_GPU = re.compile(r'SWEET GPU: 5s: (\d+) submits \((\d+) missed\), GPU busy (\d+) ms \((\d+)%\), longest (\d+) us, '
                   r'mean (\d+) us;?(.*)$')
R_OWN = re.compile(r'(\S+) (\d+)/(\d+)ms')
R_FB = re.compile(r'SWEET FB: 5s: swaps (\d+) shown (\d+) dropped (\d+).*?p50 ([\d.]+) p95 ([\d.]+) ms.*?hz (\d+)')
R_CRASH = re.compile(r'^CRASH (\S+?)\[(\d+)\] sig (\d+)')
R_PROF_START = re.compile(r'SWEET PROF: start (\S+?)\[(\d+)\] (\d+) Hz (\d+) s .*buffer (\d+) KiB at pa (0x[0-9a-fA-F]+)')
R_PROF_DONE = re.compile(r'SWEET PROF: (?:done|dump) (\S+?)\[(\d+)\] .*\| pa (0x[0-9a-fA-F]+) bytes (\d+)')
R_PROF_ERR = re.compile(r'SWEET PROF: (busy|usage|no |stop: still)')
R_TAG_SWEET = re.compile(r'^(SWEET [A-Z0-9_]+)')
R_TAG_WORD = re.compile(r'^([A-Za-z_][A-Za-z0-9_.\-]*)(?:\[\d+\])?')


def klog_tag(msg):
    m = R_TAG_SWEET.match(msg)
    if m:
        return m.group(1)
    m = R_TAG_WORD.match(msg)
    if m:
        return m.group(1)[:24]
    return '(other)'


# ---------------------------------------------------------------- helpers
def now_s():
    return time.time()


def atomic_json(path, obj):
    tmp = path + '.tmp'
    data = json.dumps(obj, separators=(',', ':'), default=str)
    try:
        with open(tmp, 'w') as f:
            f.write(data)
        os.replace(tmp, path)
    except OSError:
        with open(path, 'w') as f:
            f.write(data)


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def r1(x):
    return None if x is None else round(x, 1)


# ---------------------------------------------------------------- the collector
class Trace:
    def __init__(self, name, kind, secs, opts, tdir):
        self.name, self.kind, self.secs, self.opts, self.dir = name, kind, secs, opts, tdir
        self.state = 'starting'     # starting recording stopping transferring analyzing done failed aborted
        self.id = None
        self.t_start = now_s()
        self.t_rec = None
        self.t_stop = None
        self.t_xfer = None
        self.t_xfer_end = None
        self.zbytes = 0
        self.chunks = 0
        self.end = None
        self.error = None
        self.msg = ''
        self.zf = None
        self.out_file = None
        self.prof = None            # (pa, len)
        self.prof_fut = None
        self.next_seq = 0
        self.seq_err = 0
        self.stop_req = asyncio.Event()

    def info(self):
        t = now_s()
        x_el = ((self.t_xfer_end or t) - self.t_xfer) if self.t_xfer else 0
        return {'name': self.name, 'kind': self.kind, 'state': self.state, 'id': self.id, 'secs': self.secs,
                'opts': self.opts, 'dir': os.path.basename(self.dir), 'msg': self.msg, 'error': self.error,
                'started': self.t_start, 'recording_s': r1(((self.t_stop or t) - self.t_rec) if self.t_rec else 0),
                'zbytes': self.zbytes, 'chunks': self.chunks, 'transfer_s': r1(x_el),
                'transfer_mbps': round(self.zbytes / 1e6 / x_el, 2) if x_el > 0.05 else None, 'end': self.end}


class Collector:
    def __init__(self, a):
        self.a = a
        self.root = os.path.abspath(a.root)
        self.mon = os.path.join(self.root, 'logs', 'mon')
        self.tdir = os.path.join(self.root, 'logs', 'traces')
        os.makedirs(self.mon, exist_ok=True)
        os.makedirs(self.tdir, exist_ok=True)
        self.cfg = read_json(os.path.join(self.mon, 'config.json'), {}) or {}
        if a.link:
            self.cfg['link'] = a.link
        self.cfg.setdefault('link', 'auto')
        self.cfg.setdefault('rate_ms', 1000)
        self.cfg.setdefault('top_every', 2)
        self.cfg.setdefault('top', 15)
        self.cfg.setdefault('frames', False)
        self.phone_cfg = read_json(os.path.join(self.mon, 'phone.json'), {}) or {}
        self.state = read_json(os.path.join(self.mon, 'state.json'), {}) or {}
        self.key = None
        # connection
        self.reader = self.writer = None
        self.connected = False
        self.authed = False
        self.via = None
        self.host = None
        self.hello = None
        self.pending = collections.deque()
        self.rtt_ms = None
        self.link_since = None
        self.reconnects = 0
        self.rx_bytes = 0
        self.rx_hist = collections.deque(maxlen=20)
        self.link_msg = 'starting'
        self.kick = asyncio.Event()
        self.last_autostart = {}
        self.speed = None
        self.speed_res = None
        # data
        self.hist = collections.deque()
        self.snap = {}
        self.latest = {}            # parsed klog facts
        self.crashes = collections.deque(maxlen=20)
        self.lines = collections.deque(maxlen=20000)
        self.line_seq = 0
        self.tag_buckets = {}       # int klog second -> Counter tag -> [bytes, lines]
        self.klog_pos = None
        self.klog_boot = None
        self.klog_f = None
        self.klog_partial = b''
        self.klog_lost = 0
        self.klog_rx_hist = collections.deque(maxlen=30)
        self.klog_ok = None
        self.klog_pa = None
        self.watchers = []
        self.proc_acc_ms = 0
        self.procs_view = {'by_cpu': [], 'by_wakeups': []}
        self.frames_last = None
        self.sample_n = 0
        self.last_sample_t = None
        self.metrics_f = None
        self.metrics_day = None
        self.sse = set()
        self.trace = None
        self.traces_done = collections.deque(maxlen=50)
        self.anq = collections.deque()
        self.anev = threading.Event()
        self.pmem_seq = 1000
        self.t0 = now_s()

    # ---------------------------------------------------------------- config
    def save_cfg(self):
        atomic_json(os.path.join(self.mon, 'config.json'), self.cfg)

    def save_state(self):
        st = {'boot': self.klog_boot, 'klog_pos': self.klog_pos, 'klog_file': self.klog_f.name if self.klog_f else None,
              'klog_lost': self.klog_lost, 'saved': now_s()}
        atomic_json(os.path.join(self.mon, 'state.json'), st)

    def load_key(self):
        p = os.path.join(self.root, 'agent', 'sweetmon.key')
        try:
            k = open(p).read().strip().split()[0]
            if not re.fullmatch(r'[0-9a-fA-F]{8,128}', k):
                raise ValueError('not hex')
            return k
        except (OSError, IndexError, ValueError) as e:
            log.warning('no usable key in %s (%s): collector.py --make-key', p, e)
            return None

    def pa_candidates(self):
        c = []
        if self.cfg.get('klog_pa'):
            c.append((self.cfg['klog_pa'], 'config.json'))
        if self.hello and self.hello.get('klog_pa'):
            c.append((self.hello['klog_pa'], 'phone'))
        try:
            for ln in open(os.path.join(self.root, 'KNOWN-GOOD.txt'), errors='replace'):
                m = re.match(r'\s*Kernel:\s*(builds/xnu/[^\s/]+)', ln)
                if m:
                    t = open(os.path.join(self.root, m.group(1), 'KLOG_PA.txt')).read()
                    pm = re.search(r'0x[0-9a-fA-F]+', t)
                    if pm:
                        c.append((pm.group(0), 'KNOWN-GOOD ' + m.group(1)))
                    break
        except OSError:
            pass
        c.append((DEFAULT_KLOG_PA, 'built-in default (r63a)'))
        seen, out = set(), []
        for pa, src in c:
            if pa.lower() not in seen:
                seen.add(pa.lower())
                out.append((pa, src))
        return out

    # ---------------------------------------------------------------- SSE
    def emit(self, ev, data):
        if not self.sse:
            return
        msg = ('event: %s\ndata: %s\n\n' % (ev, json.dumps(data, separators=(',', ':'), default=str))).encode()
        for q in list(self.sse):
            try:
                q.put_nowait(msg)
            except asyncio.QueueFull:      # a stuck browser tab: drop it (it reconnects and gets init again)
                self.sse.discard(q)

    # ---------------------------------------------------------------- link
    def wifi_host(self):
        if self.a.wifi_host:
            return self.a.wifi_host
        return self.phone_cfg.get('wifi')

    async def tcp_ok(self, host, port, timeout):
        try:
            r, w = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
            w.close()
            return True
        except (OSError, asyncio.TimeoutError):
            return False

    async def try_connect(self, host):
        """returns (reader, writer) or None; 'refused' marks a host that is up but has no daemon"""
        try:
            return await asyncio.wait_for(asyncio.open_connection(host, self.a.port), self.a.connect_timeout)
        except ConnectionRefusedError:
            await self.maybe_autostart(host)
        except (OSError, asyncio.TimeoutError):
            pass
        return None

    async def maybe_autostart(self, host):
        if self.a.no_autostart:
            return
        t = now_s()
        if t - self.last_autostart.get(host, 0) < self.a.autostart_every:
            return
        if not await self.tcp_ok(host, self.a.ssh_port, 2):
            return
        self.last_autostart[host] = t
        cmd = [self.a.ssh_bin, '-i', os.path.expanduser('~/.ssh/redfin-claude'), '-o', 'StrictHostKeyChecking=no',
               '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=5', '-o', 'LogLevel=ERROR',
               '-o', 'BatchMode=yes', 'root@' + host, '/var/local/bin/sweetmon -D </dev/null >/dev/null 2>&1']
        log.info('%s answers ssh but not %d: starting the daemon (%s)', host, self.a.port, ' '.join(cmd[-2:]))
        self.link_msg = 'starting the daemon on %s over ssh' % host

        def run():
            try:
                r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
                log.info('ssh start: exit %d %s', r.returncode, (r.stdout + r.stderr).decode(errors='replace').strip()[:300])
            except (OSError, subprocess.SubprocessError) as e:
                log.warning('ssh start failed: %s', e)
        await asyncio.get_running_loop().run_in_executor(None, run)

    async def link_loop(self):
        while True:
            mode = self.cfg.get('link', 'auto')
            cands = []
            for via in (self.link_order() if mode == 'auto' else [mode]):
                host = self.a.usb_host if via == 'usb' else self.wifi_host()
                if host:
                    cands.append((via, host))
            got = None
            for via, host in cands:
                rw = await self.try_connect(host)
                if rw:
                    got = (via, host, rw)
                    break
            if not got:
                if not cands:
                    self.link_msg = 'no Wi-Fi address known yet (connect over USB once)'
                elif 'starting the daemon' not in self.link_msg:
                    self.link_msg = 'no answer from %s' % ', '.join('%s %s' % c for c in cands)
                self.emit('link', self.link_info())
                self.kick.clear()
                try:
                    await asyncio.wait_for(self.kick.wait(), self.a.retry)
                except asyncio.TimeoutError:
                    pass
                continue
            via, host, (r, w) = got
            try:
                sock = w.get_extra_info('socket')
                if sock:
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
            except OSError:
                pass
            await self.session(via, host, r, w)
            self.reconnects += 1
            await asyncio.sleep(0.5)

    def link_order(self):
        """auto: the link with the higher measured speed test result first (logs/mon/phone.json), USB when unknown"""
        sp = self.phone_cfg.get('speed') or {}
        u = (sp.get('usb') or {}).get('mbps')
        w = (sp.get('wifi') or {}).get('mbps')
        if u is not None and w is not None and w > u:
            return ['wifi', 'usb']
        return ['usb', 'wifi']

    def link_info(self):
        rx = None
        if len(self.rx_hist) >= 2:
            (t0, b0), (t1, b1) = self.rx_hist[0], self.rx_hist[-1]
            rx = (b1 - b0) / (t1 - t0) if t1 > t0 else None
        return {'mode': self.cfg.get('link'), 'via': self.via, 'host': self.host, 'connected': self.connected,
                'authed': self.authed, 'rtt_ms': r1(self.rtt_ms), 'since': self.link_since, 'reconnects': self.reconnects,
                'rx_bps': rx and int(rx), 'msg': self.link_msg, 'wifi_host': self.wifi_host(), 'usb_host': self.a.usb_host,
                'speed': self.phone_cfg.get('speed') or {}, 'preferred': self.link_order()[0]}

    async def send(self, line):
        if not self.writer:
            raise ConnectionError('not connected')
        p = line.encode()
        self.writer.write(struct.pack('<IB', len(p) + 1, ord('C')) + p)
        await self.writer.drain()

    async def cmd(self, line, timeout=10.0):
        """send one command, wait for its R reply (dict)"""
        if not self.connected:
            return {'cmd': line.split()[0] if line.split() else '', 'ok': False, 'msg': 'not connected'}
        fut = asyncio.get_running_loop().create_future()
        self.pending.append((line, fut))
        try:
            await self.send(line)
            return await asyncio.wait_for(asyncio.shield(fut), timeout)
        except asyncio.TimeoutError:
            return {'cmd': line.split()[0], 'ok': False, 'msg': 'timeout (%.0f s)' % timeout}
        except (ConnectionError, OSError) as e:
            return {'cmd': line.split()[0], 'ok': False, 'msg': 'link: %s' % e}

    async def read_frame(self, r):
        h = await r.readexactly(5)
        n, t = struct.unpack('<IB', h)
        if n < 1 or n > MAX_FRAME + 64:
            raise ValueError('bad frame length %d' % n)
        p = await r.readexactly(n - 1) if n > 1 else b''
        self.rx_bytes += n + 4
        return chr(t), p

    async def session(self, via, host, r, w):
        self.reader, self.writer = r, w
        self.via, self.host = via, host
        self.connected, self.authed = True, False
        self.link_msg = 'connected, waiting for hello'
        tasks = []
        try:
            t, p = await asyncio.wait_for(self.read_frame(r), 5)
            if t != 'H':
                raise ValueError('first frame %r, not H' % t)
            self.on_hello(json.loads(p))
            rd = asyncio.ensure_future(self.reader_loop(r))
            tasks.append(rd)
            self.key = self.load_key()
            if not self.key:
                self.link_msg = 'no key: agent/sweetmon.key (collector.py --make-key, then mon install)'
                raise ConnectionError(self.link_msg)
            rep = await self.cmd('auth ' + self.key)
            if not rep.get('ok'):
                self.link_msg = 'auth refused: %s' % rep.get('msg')
                log.warning('%s %s: %s', via, host, self.link_msg)
                await asyncio.sleep(8)
                raise ConnectionError(self.link_msg)
            self.authed = True
            self.link_since = now_s()
            self.link_msg = 'ok'
            log.info('connected via %s %s (daemon pid %s, version %s, up %s s)', via, host, self.hello.get('pid'),
                     self.hello.get('version'), self.hello.get('uptime_s'))
            self.emit('hello', {'hello': self.hello, 'link': self.link_info()})
            await self.cmd('rate %d %d' % (self.cfg['rate_ms'], self.cfg['top_every']))
            await self.cmd('top %d' % self.cfg['top'])
            await self.start_klog()
            if self.cfg.get('frames'):
                await self.cmd('frames on')
            tasks.append(asyncio.ensure_future(self.ping_loop()))
            if self.cfg.get('link') == 'auto' and via != self.link_order()[0]:
                tasks.append(asyncio.ensure_future(self.better_link_loop(via)))
            await rd
        except (asyncio.IncompleteReadError, ConnectionError, OSError, ValueError, asyncio.TimeoutError) as e:
            if self.authed or not isinstance(e, asyncio.IncompleteReadError):
                log.info('link %s %s ended: %s', via, host, e or type(e).__name__)
        finally:
            for tk in tasks:
                tk.cancel()
            self.connected = self.authed = False
            try:
                w.close()
            except Exception:
                pass
            self.reader = self.writer = None
            while self.pending:
                _, f = self.pending.popleft()
                if not f.done():
                    f.set_result({'ok': False, 'msg': 'link lost'})
            if self.link_msg == 'ok':
                self.link_msg = 'link lost'
            self.write_now_link()
            self.klog_flush_partial()
            self.save_state()
            tr = self.trace
            if tr and tr.state in ('transferring',) and tr.kind != 'prof':
                self.trace_fail(tr, 'link lost during the transfer (%d bytes received)' % tr.zbytes)
            self.emit('link', self.link_info())

    async def reader_loop(self, r):
        while True:
            t, p = await self.read_frame(r)
            try:
                self.on_frame(t, p)
            except Exception as e:      # never let one bad frame end the session
                log.exception('bad %r frame (%d bytes): %s', t, len(p), e)

    async def ping_loop(self):
        while True:
            await asyncio.sleep(self.a.ping_every)
            t0 = time.perf_counter()
            rep = await self.cmd('ping %d' % int(t0 * 1000), timeout=10)
            if rep.get('ok'):
                self.rtt_ms = (time.perf_counter() - t0) * 1000

    async def better_link_loop(self, via):
        """auto mode on the slower (or fallback) link: switch when the preferred link answers again. The probe is a
        bare TCP connect (no auth), which does not take the daemon's client slot."""
        while True:
            await asyncio.sleep(self.a.usb_probe_every)
            if self.cfg.get('link') != 'auto':
                return
            best = self.link_order()[0]
            if best == via:
                return
            if self.trace or self.speed is not None:
                continue
            host = self.a.usb_host if best == 'usb' else self.wifi_host()
            if host and await self.tcp_ok(host, self.a.port, 1.5):
                log.info('%s answers (preferred: faster by speed test): switching from %s', best, via)
                self.writer.close()
                return

    def on_hello(self, h):
        self.hello = h
        self.hello['_t'] = now_s()
        ifs = h.get('ifaces') or {}
        wifi = ifs.get('en0')
        if not wifi:
            for k, v in ifs.items():
                if v and not str(v).startswith(('127.', '192.168.7.')):
                    wifi = v
                    break
        if wifi and wifi != self.phone_cfg.get('wifi'):
            self.phone_cfg['wifi'] = wifi
            log.info('phone Wi-Fi address %s', wifi)
        self.phone_cfg['last_hello'] = h
        atomic_json(os.path.join(self.mon, 'phone.json'), self.phone_cfg)
        boot = h.get('boottime')
        if boot is not None:
            boot = int(boot)
            if self.klog_boot is None and self.state.get('boot') and abs(self.state['boot'] - boot) <= 3:
                self.klog_boot = self.state['boot']
                self.klog_pos = self.state.get('klog_pos')
                self.klog_lost = self.state.get('klog_lost', 0)
            if self.klog_boot is None or abs(self.klog_boot - boot) > 3:
                if self.klog_boot is not None:
                    log.info('new boot (boottime %s, was %s): new klog file', boot, self.klog_boot)
                self.klog_boot = boot
                self.klog_pos = None
                self.klog_lost = 0
                self.latest = {}
                self.crashes.clear()
                self.tag_buckets.clear()
                if self.klog_f:
                    self.klog_f.close()
                    self.klog_f = None
            if not self.klog_f:
                self.klog_f = open(os.path.join(self.mon, 'klog-%d.txt' % self.klog_boot), 'ab')
            self.save_state()

    async def start_klog(self):
        if self.cfg.get('klog_off'):
            return
        self.klog_ok = None
        refused = []
        for pa, src in self.pa_candidates():
            rep = await self.cmd('klog %s' % pa, timeout=15)
            if rep.get('ok'):
                self.klog_pa = pa
                self.klog_ok = 'ok (%s from %s)' % (pa, src) + ('; refused: ' + '; '.join(refused) if refused else '')
                break
            refused.append('%s (%s): %s' % (pa, src, rep.get('msg')))
            log.warning('klog %s (%s) refused: %s', pa, src, rep.get('msg'))
            self.klog_ok = 'klog %s (%s) refused: %s' % (pa, src, rep.get('msg'))
        else:
            if self.klog_ok is None:
                self.klog_ok = 'no KLOG_PA known: mon klog-pa PA'
            return
        if self.klog_pos is not None:
            rep = await self.cmd('klog from %d' % self.klog_pos, timeout=15)
            log.info('klog from %d: %s', self.klog_pos, rep.get('msg') or rep.get('ok'))

    # ---------------------------------------------------------------- frames from the phone
    def on_frame(self, t, p):
        if t == 'R':
            rep = json.loads(p)
            # replies come in command order; one whose command word does not match the oldest pending one means the
            # phone dropped that reply: resolve the skipped ones as lost so later replies stay aligned
            idx = 0
            cw = rep.get('cmd')
            if cw:
                for i, (line, _) in enumerate(self.pending):
                    if (line.split() or [''])[0] == cw:
                        idx = i
                        break
                else:
                    idx = -1
            if idx < 0 or not self.pending:
                log.info('unsolicited reply %s', str(rep)[:300])
                return
            for _ in range(idx):
                line, fut = self.pending.popleft()
                log.warning('no reply to %r', line[:60])
                if not fut.done():
                    fut.set_result({'cmd': line.split()[0], 'ok': False, 'msg': 'no reply from the phone'})
            line, fut = self.pending.popleft()
            if not fut.done():
                fut.set_result(rep)
        elif t == 'S':
            self.on_sample(json.loads(p))
        elif t == 'K':
            if len(p) >= 8:
                self.on_klog(struct.unpack_from('<Q', p, 0)[0], p[8:])
        elif t == 'T':
            if len(p) >= 8:
                tid, seq = struct.unpack_from('<II', p, 0)
                self.on_tchunk(tid, seq, p[8:])
        elif t == 'E':
            self.on_tend(json.loads(p))
        elif t == 'F':
            f = json.loads(p)
            f['_t'] = now_s()
            self.frames_last = f
            self.emit('frames', f)
        elif t == 'P':
            if self.speed is not None:
                self.speed['bytes'] += len(p)
                if self.speed['t_first'] is None:
                    self.speed['t_first'] = time.perf_counter()
                self.speed['t_last'] = time.perf_counter()
        elif t == 'H':
            self.on_hello(json.loads(p))
        else:
            log.info('unknown frame type %r (%d bytes)', t, len(p))

    # ---------------------------------------------------------------- klog
    def on_klog(self, pos, data):
        if not data:
            return
        if self.klog_pos is not None:
            end = pos + len(data)
            if end <= self.klog_pos:
                return                      # all already have
            if pos < self.klog_pos:
                data = data[self.klog_pos - pos:]
                pos = self.klog_pos
            elif pos > self.klog_pos:
                lost = pos - self.klog_pos
                self.klog_lost += lost
                log.warning('klog gap: %d bytes lost (ring overwritten before we read them)', lost)
                self.klog_flush_partial()
                self.klog_write(b'\n[sweetmon: %d bytes of kernel log lost here]\n' % lost, marker=True)
        self.klog_pos = pos + len(data)
        self.klog_rx_hist.append((now_s(), len(data)))
        self.klog_write(data)

    def klog_write(self, data, marker=False):
        if self.klog_f:
            self.klog_f.write(data)
            self.klog_f.flush()
        if marker:
            return
        buf = self.klog_partial + data
        parts = buf.split(b'\n')
        self.klog_partial = parts.pop()
        if len(self.klog_partial) > 8192:
            parts.append(self.klog_partial)
            self.klog_partial = b''
        out = []
        for raw in parts:
            s = raw.decode('utf-8', 'replace').rstrip('\r')
            if not s:
                continue
            self.line_seq += 1
            self.lines.append((self.line_seq, s))
            out.append(s)
            try:
                self.parse_line(s, len(raw) + 1)
            except Exception as e:
                log.debug('parse %r: %s', s[:120], e)
        if out:
            self.emit('klog', {'lines': out[-400:], 'seq': self.line_seq, 'skipped': max(0, len(out) - 400)})
        if self.sample_n % 5 == 0:
            self.save_state()

    def klog_flush_partial(self):
        if self.klog_partial:
            self.klog_write(b'\n')

    def parse_line(self, s, nbytes):
        m = R_TS.match(s)
        if m:
            ts, msg = float(m.group(1)), m.group(2)
        else:
            ts, msg = self.latest.get('_ts', 0.0), s
        self.latest['_ts'] = max(ts, self.latest.get('_ts', 0.0))
        sec = int(ts)
        b = self.tag_buckets.get(sec)
        if b is None:
            b = self.tag_buckets[sec] = collections.defaultdict(lambda: [0, 0])
            if len(self.tag_buckets) > 1200:
                for k in sorted(self.tag_buckets)[:len(self.tag_buckets) - 1000]:
                    del self.tag_buckets[k]
        e = b[klog_tag(msg)]
        e[0] += nbytes
        e[1] += 1
        for w in list(self.watchers):
            rx, fut, min_ts = w
            if ts >= min_ts and not fut.done():
                mm = rx.search(msg)
                if mm:
                    fut.set_result((ts, mm, msg))
        if not msg.startswith(('SWEET', 'CRASH')):
            return
        if msg.startswith('SWEET THERMAL: silver'):
            m = R_TEMP.search(msg)
            if m:
                v = [float(x) for x in m.groups()]
                self.latest['temp'] = (ts, dict(zip(TEMP_KEYS, v)))
        elif msg.startswith('SWEET THERMAL: level'):
            m = R_LEVEL.search(msg)
            if m:
                g = m.groups()
                self.latest['level'] = (ts, {'from': int(g[0]), 'level': int(g[1]), 'hot_c': float(g[2]),
                                             'cap_mhz': {'silver': int(g[3]), 'gold': int(g[4]), 'prime': int(g[5])},
                                             'gpu_cap': int(g[6])})
        elif msg.startswith('SWEET CPUFREQ: busy'):
            m = R_CPUF.search(msg)
            if m:
                g = m.groups()
                busy = [int(x) for x in (g[0] + ' ' + g[1] + ' ' + g[2]).split()]
                self.latest['cpufreq'] = (ts, {'busy': busy, 'idx': [int(g[3]), int(g[5]), int(g[7])],
                                               'mhz': [int(g[4]), int(g[6]), int(g[8])]})
        elif msg.startswith('SWEET BATTERY: '):
            m = R_BAT.search(msg)
            if m:
                g = m.groups()
                self.latest['battery'] = (ts, {'mv': int(g[0]), 'ma': int(g[1]), 'pct': int(g[2]), 'ext': int(g[3]),
                                               'chg': int(g[4]), 'temp_c': int(g[5]) / 100 if g[5] else None})
        elif msg.startswith('SWEET GPU: 5s'):
            m = R_GPU.search(msg)
            if m:
                g = m.groups()
                own = [{'name': o[0], 'submits': int(o[1]), 'ms': int(o[2])} for o in R_OWN.findall(g[6] or '')]
                own.sort(key=lambda o: -o['ms'])
                self.latest['gpu'] = (ts, {'submits': int(g[0]), 'missed': int(g[1]), 'busy_ms': int(g[2]),
                                           'busy_pct': int(g[3]), 'longest_us': int(g[4]), 'mean_us': int(g[5]),
                                           'owners': own})
        elif msg.startswith('SWEET FB: 5s'):
            m = R_FB.search(msg)
            if m:
                g = m.groups()
                self.latest['fb'] = (ts, {'swaps': int(g[0]), 'shown': int(g[1]), 'dropped': int(g[2]),
                                          'fps': round(int(g[1]) / 5, 1), 'p50_ms': float(g[3]), 'p95_ms': float(g[4]),
                                          'hz': int(g[5])})
        elif msg.startswith('CRASH '):
            m = R_CRASH.match(msg)
            if m:
                self.crashes.appendleft({'ts': ts, 'name': m.group(1), 'pid': int(m.group(2)), 'sig': int(m.group(3)),
                                         'line': msg[:200]})

    def top_tags(self, up, secs=60, n=8):
        acc = collections.defaultdict(lambda: [0, 0])
        lo = up - secs
        for sec, b in self.tag_buckets.items():
            if sec >= lo:
                for k, v in b.items():
                    acc[k][0] += v[0]
                    acc[k][1] += v[1]
        span = max(1.0, min(secs, up)) if up else secs
        rows = sorted(acc.items(), key=lambda kv: -kv[1][0])[:n]
        return [{'tag': k, 'bps': int(v[0] / span), 'lines_s': round(v[1] / span, 2)} for k, v in rows]

    def watch(self, rx, min_ts):
        fut = asyncio.get_running_loop().create_future()
        w = (rx, fut, min_ts)
        self.watchers.append(w)
        return fut, w

    def unwatch(self, w):
        if w in self.watchers:
            self.watchers.remove(w)

    # ---------------------------------------------------------------- samples
    def fresh(self, key, up, max_age=12):
        v = self.latest.get(key)
        if not v:
            return None, None
        ref = max(up or 0, self.latest.get('_ts', 0))
        return v[1], max(0.0, ref - v[0])

    def on_sample(self, s):
        t = now_s()
        self.sample_n += 1
        up = s.get('up') or 0
        dt_ms = s.get('dt_ms') or self.cfg['rate_ms']
        busy = []
        for c in s.get('cpu') or []:
            try:
                u, sy, idle, ni = c[:4]
                tot = u + sy + idle + ni
                busy.append(round(100.0 * (u + sy + ni) / tot, 1) if tot > 0 else 0.0)
            except (TypeError, ValueError):
                busy.append(None)
        cl = {}
        cf, cf_age = self.fresh('cpufreq', up)
        for i, (nm, rg) in enumerate(CLUSTERS):
            vals = [busy[j] for j in rg if j < len(busy) and busy[j] is not None]
            cl[nm] = {'busy': r1(sum(vals) / len(vals)) if vals else None,
                      'mhz': cf['mhz'][i] if cf else None, 'idx': cf['idx'][i] if cf else None}
        temps = {}
        for k, v in (s.get('temp') or {}).items():
            if isinstance(v, (int, float)) and v > -1000:
                temps[k] = round(v / 10.0, 1)
        tsrc = 'sysctl'
        kt, kt_age = self.fresh('temp', up)
        if not [k for k in temps if k != 'max'] and kt:
            temps = dict(kt)
            tsrc = 'klog'
        if temps:
            temps['max'] = max(v for k, v in temps.items() if k != 'max') if len(temps) > 1 or 'max' not in temps \
                else temps['max']
        lvl, _ = self.fresh('level', up)
        bat, bat_age = self.fresh('battery', up)
        gpu, gpu_age = self.fresh('gpu', up)
        fb, fb_age = self.fresh('fb', up)
        vm = s.get('vm') or {}
        pk = vm.get('page_kb') or 16
        mb = lambda k: round(vm[k] * pk / 1024, 1) if isinstance(vm.get(k), (int, float)) else None
        dts = dt_ms / 1000.0 if dt_ms else 1.0
        mem = {'free_mb': mb('free'), 'active_mb': mb('active'), 'inactive_mb': mb('inactive'),
               'wired_mb': mb('wired'), 'compressed_mb': mb('compressed'), 'spec_mb': mb('spec'),
               'pageins_s': r1(vm.get('pageins', 0) / dts) if 'pageins' in vm else None,
               'swapins_s': r1(vm.get('swapins', 0) / dts) if 'swapins' in vm else None,
               'faults_s': r1(vm.get('faults', 0) / dts) if 'faults' in vm else None}
        used = [mem[k] for k in ('active_mb', 'inactive_mb', 'wired_mb', 'compressed_mb') if mem[k] is not None]
        mem['used_mb'] = r1(sum(used)) if used else None
        self.proc_acc_ms += dt_ms
        if s.get('procs') is not None:
            iv = max(self.proc_acc_ms, 1) / 1000.0
            self.proc_acc_ms = 0
            rows = []
            for p in s['procs']:
                try:
                    pid, name, cpu_ms, wk, fp_kb, thr = p[:6]
                    dio = p[6] if len(p) > 6 else 0
                    rows.append({'pid': pid, 'name': name, 'cpu_pct': r1(cpu_ms / iv / 10.0),
                                 'wakeups_s': r1(wk / iv), 'mem_mb': r1(fp_kb / 1024.0), 'threads': thr,
                                 'disk_kbs': r1(dio / iv)})
                except (TypeError, ValueError):
                    continue
            self.procs_view = {'by_cpu': sorted(rows, key=lambda r: -(r['cpu_pct'] or 0)),
                               'by_wakeups': sorted(rows, key=lambda r: -(r['wakeups_s'] or 0))[:10],
                               'interval_s': round(iv, 2), 't': t}
        sf = s.get('self') or {}
        selfv = {'cpu_pct': r1((sf.get('cpu_ms') or 0) / dt_ms * 100) if dt_ms else None,
                 'cpu_ms_s': r1((sf.get('cpu_ms') or 0) / dt_ms * 1000) if dt_ms else None,
                 'rss_mb': r1((sf.get('rss_kb') or 0) / 1024.0), 'tx_bps': sf.get('tx_bps'), 'klog_bps': sf.get('klog_bps')}
        krx = None
        if len(self.klog_rx_hist) >= 2:
            span = self.klog_rx_hist[-1][0] - self.klog_rx_hist[0][0]
            if span > 1 and t - self.klog_rx_hist[-1][0] < 10:
                krx = int(sum(b for _, b in list(self.klog_rx_hist)[1:]) / span)
        fr = self.frames_last if self.frames_last and t - self.frames_last['_t'] < 5 else None
        snap = {
            't': t, 'time': dt.datetime.now().isoformat(timespec='seconds'),
            'link': self.link_info(),
            'phone': {'uptime_s': up, 'daemon_pid': (self.hello or {}).get('pid'),
                      'version': (self.hello or {}).get('version'), 'boottime': self.klog_boot,
                      'ifaces': (self.hello or {}).get('ifaces'), 'ncpu': (self.hello or {}).get('ncpu'),
                      'nproc': s.get('nproc'), 'rate_ms': self.cfg['rate_ms']},
            'cpu': {'busy': busy, 'avg': r1(sum(b for b in busy if b is not None) / len(busy)) if busy else None,
                    'clusters': cl, 'load': s.get('load'), 'kernel_busy': cf['busy'] if cf else None,
                    'cpufreq_age_s': r1(cf_age)},
            'temp': temps, 'temp_source': tsrc,
            'thermal': {'level': lvl['level'] if lvl else 0, 'cap_mhz': lvl['cap_mhz'] if lvl else None,
                        'gpu_cap': lvl['gpu_cap'] if lvl else None, 'hot_c': lvl['hot_c'] if lvl else None,
                        'since_up_s': self.latest['level'][0] if lvl else None},
            'battery': dict(bat, age_s=r1(bat_age)) if bat else None,
            'gpu': dict(gpu, age_s=r1(gpu_age)) if gpu else None,
            'fb': dict(fb, age_s=r1(fb_age)) if fb else None,
            'mem': mem,
            'procs': {'by_cpu': self.procs_view['by_cpu'][:self.cfg['top']], 'by_wakeups': self.procs_view['by_wakeups'],
                      'nproc': s.get('nproc'), 'interval_s': self.procs_view.get('interval_s')},
            'klog': {'bps_kernel': s.get('klog_bps'), 'bps_rx': krx,
                     'top_tags': self.top_tags(self.latest.get('_ts') or up),
                     'file': os.path.relpath(self.klog_f.name, self.root) if self.klog_f else None,
                     'pos': self.klog_pos, 'lost_bytes': self.klog_lost, 'status': self.klog_ok, 'pa': self.klog_pa},
            'crashes': list(self.crashes)[:10],
            'self': selfv,
            'frames': fr,
            'frames_on': bool(self.cfg.get('frames')),
            'trace': self.trace.info() if self.trace else (self.traces_done[0] if self.traces_done else None),
        }
        snap['hot'] = self.explain(snap)
        self.snap = snap
        self.rx_hist.append((t, self.rx_bytes))
        h = {'t': round(t, 2), 'up': up, 'busy': busy, 'mhz': [cl[c]['mhz'] for c in ('silver', 'gold', 'prime')],
             'temp': temps, 'lvl': snap['thermal']['level'], 'gpu': gpu['busy_pct'] if gpu and gpu_age is not None
             and gpu_age < 12 else None, 'bat_ma': bat['ma'] if bat else None, 'bat_pct': bat['pct'] if bat else None,
             'mem_free': mem['free_mb'], 'mem_used': mem['used_mb'], 'mem_comp': mem['compressed_mb'],
             'klog_bps': s.get('klog_bps') if s.get('klog_bps') is not None else krx, 'self_cpu': selfv['cpu_pct'],
             'self_ms': selfv['cpu_ms_s'], 'fps': fr['fps'] if fr else None,
             'fb_fps': fb['fps'] if fb and fb_age is not None and fb_age < 12 else None, 'rtt': r1(self.rtt_ms)}
        self.hist.append(h)
        while self.hist and (t - self.hist[0]['t'] > self.a.history_secs or len(self.hist) > 40000):
            self.hist.popleft()
        try:
            atomic_json(os.path.join(self.mon, 'now.json'), snap)
            self.write_metrics(h, snap)
        except OSError as e:
            log.warning('writing now.json/metrics: %s', e)
        self.emit('sample', {'snap': snap, 'h': h})

    def now_view(self):
        if not self.snap:
            return {'link': self.link_info(), 'msg': 'no sample yet'}
        v = dict(self.snap)
        v['link'] = self.link_info()
        v['age_s'] = round(now_s() - self.snap['t'], 1)
        v['stale'] = not self.authed
        if self.trace:
            v['trace'] = self.trace.info()
        return v

    def write_now_link(self):
        """link changes between samples (phone gone): now.json shows it, with the last sample marked stale"""
        try:
            atomic_json(os.path.join(self.mon, 'now.json'), self.now_view())
        except OSError:
            pass

    def write_metrics(self, h, snap):
        day = time.strftime('%Y%m%d')
        if day != self.metrics_day:
            if self.metrics_f:
                self.metrics_f.close()
            self.metrics_f = open(os.path.join(self.mon, 'metrics-%s.jsonl' % day), 'a')
            self.metrics_day = day
        row = dict(h)
        if snap['procs']['by_cpu'] and self.procs_view.get('t') == snap['t']:
            row['top'] = [[p['name'], p['cpu_pct'], p['wakeups_s']] for p in snap['procs']['by_cpu'][:5]]
        self.metrics_f.write(json.dumps(row, separators=(',', ':')) + '\n')
        if self.sample_n % 10 == 0:
            self.metrics_f.flush()

    def explain(self, s):
        """'what is making it hot/slow': short human lines, most important first"""
        out = []
        temps = s['temp']
        th = s['thermal']
        if temps.get('max') is not None:
            hot = sorted(((v, k) for k, v in temps.items() if k != 'max'), reverse=True)[:3]
            out.append('max %.1f C (%s)' % (temps['max'], ', '.join('%s %.1f' % (k, v) for v, k in hot)))
        if th['level']:
            caps = th.get('cap_mhz') or {}
            c = ', '.join('%s %d MHz' % (k, v) for k, v in caps.items() if v)
            out.append('thermal level %d: capped %s%s' % (th['level'], c or '-', ', gpu cap %s' % th['gpu_cap']
                                                          if th.get('gpu_cap') else ''))
        cpu = s['cpu']
        if cpu['busy']:
            hi = [(b, i) for i, b in enumerate(cpu['busy']) if b is not None and b >= 60]
            if hi:
                out.append('busy cores: ' + ', '.join('cpu%d %d%%' % (i, b) for b, i in hi))
        pr = s['procs']['by_cpu']
        if pr:
            tops = [p for p in pr[:4] if (p['cpu_pct'] or 0) >= 5]
            if tops:
                out.append('top CPU: ' + ', '.join('%s %.0f%%' % (p['name'], p['cpu_pct']) for p in tops))
        wk = s['procs']['by_wakeups']
        if wk and (wk[0]['wakeups_s'] or 0) >= 100:
            out.append('wakeups: ' + ', '.join('%s %.0f/s' % (p['name'], p['wakeups_s']) for p in wk[:3]
                                               if (p['wakeups_s'] or 0) >= 50))
        g = s['gpu']
        if g and g.get('busy_pct') is not None and (g.get('age_s') or 0) < 12 and g['busy_pct'] >= 10:
            out.append('GPU %d%% (%s)' % (g['busy_pct'], ', '.join('%s %d ms' % (o['name'], o['ms'])
                                                                    for o in g['owners'][:3])))
        k = s['klog']
        if k.get('bps_kernel') and k['bps_kernel'] > 4096:
            out.append('kernel log %.1f KB/s (%s)' % (k['bps_kernel'] / 1024, ', '.join(
                '%s %.1f KB/s' % (x['tag'], x['bps'] / 1024) for x in k['top_tags'][:3])))
        b = s['battery']
        if b and b.get('ma') is not None and b['ma'] < -800:
            out.append('battery drain %d mA' % -b['ma'])
        sf = s['self']
        if sf.get('cpu_pct') and sf['cpu_pct'] > 3:
            out.append('sweetmon itself %.1f%% CPU (%.0f ms/s)' % (sf['cpu_pct'], sf.get('cpu_ms_s') or 0))
        if s['crashes'] and s['phone']['uptime_s'] and s['phone']['uptime_s'] - s['crashes'][0]['ts'] < 60:
            c = s['crashes'][0]
            out.append('crash %s[%d] sig %d %.0f s ago' % (c['name'], c['pid'], c['sig'], s['phone']['uptime_s'] - c['ts']))
        return out

    # ---------------------------------------------------------------- traces
    def new_trace_dir(self, name):
        d = os.path.join(self.tdir, '%s-%s' % (name, time.strftime('%m%d-%H%M%S')))
        n = 1
        base = d
        while os.path.exists(d):
            n += 1
            d = '%s-%d' % (base, n)
        os.makedirs(d)
        return d

    def trace_meta(self, tr):
        m = tr.info()
        try:
            atomic_json(os.path.join(tr.dir, 'meta.json'), m)
        except OSError:
            pass
        self.emit('trace', m)
        return m

    def trace_fail(self, tr, msg):
        tr.state = 'failed'
        tr.error = msg
        log.warning('trace %s failed: %s', tr.name, msg)
        if tr.zf:
            tr.zf.close()
            tr.zf = None
        self.trace_finish(tr)

    def trace_finish(self, tr):
        self.trace_meta(tr)
        if self.trace is tr:
            self.trace = None
        self.traces_done.appendleft(tr.info())

    async def trace_start(self, req):
        if self.trace:
            return {'ok': False, 'msg': 'a trace is running (%s, %s)' % (self.trace.name, self.trace.state)}
        kind = req.get('kind') or 'kdebug'
        name = re.sub(r'[^A-Za-z0-9._-]', '_', str(req.get('name') or kind))[:48]
        opts = dict(req.get('opts') or {})
        if kind not in ('kdebug', 'prof'):
            return {'ok': False, 'msg': 'kind: kdebug or prof'}
        if not self.authed:
            return {'ok': False, 'msg': 'not connected to the phone'}
        secs = int(req.get('secs') or opts.pop('secs', 0) or (10 if kind == 'prof' else 60))
        tr = Trace(name, kind, secs, opts, self.new_trace_dir(name))
        self.trace = tr
        if kind == 'kdebug':
            o = {'secs': secs}
            for k, v in opts.items():
                if re.fullmatch(r'[a-z_]+', str(k)) and re.fullmatch(r'[A-Za-z0-9,._-]+', str(v)):
                    o[k] = v
            line = 'trace start kdebug ' + ' '.join('%s=%s' % kv for kv in o.items())
            rep = await self.cmd(line, timeout=15)
            if not rep.get('ok'):
                self.trace_fail(tr, 'phone: %s' % rep.get('msg'))
                return {'ok': False, 'msg': tr.error}
            tr.id = rep.get('id')
            tr.t_rec = now_s()
            tr.state = 'recording'
            tr.msg = line
            log.info('trace %s started (id %s): %s', name, tr.id, line)
            asyncio.ensure_future(self.trace_watchdog(tr))
        else:
            asyncio.ensure_future(self.prof_run(tr))
        self.trace_meta(tr)
        return {'ok': True, 'msg': 'started', 'trace': tr.info()}

    async def trace_watchdog(self, tr):
        # the phone ends a trace by itself at secs; if no data shows up long after that, mark it failed
        lim = tr.secs + self.a.trace_grace
        while self.trace is tr and tr.state in ('recording', 'stopping'):
            await asyncio.sleep(1)
            if tr.state == 'recording' and now_s() - tr.t_rec > lim:
                self.trace_fail(tr, 'no trace data %d s after the start' % lim)
        while self.trace is tr and tr.state == 'transferring':
            last = tr.zbytes
            await asyncio.sleep(30)
            if self.trace is tr and tr.state == 'transferring' and tr.zbytes == last:
                self.trace_fail(tr, 'transfer stalled at %d bytes' % tr.zbytes)

    async def trace_stop(self, abort=False):
        tr = self.trace
        if not tr:
            return {'ok': False, 'msg': 'no trace running'}
        if tr.kind == 'prof':
            tr.stop_req.set()
            return {'ok': True, 'msg': 'stopping the profiler', 'trace': tr.info()}
        if tr.state not in ('recording',):
            return {'ok': False, 'msg': 'trace is %s' % tr.state, 'trace': tr.info()}
        tr.state = 'stopping'
        tr.t_stop = now_s()
        rep = await self.cmd('trace abort' if abort else 'trace stop', timeout=15)
        if abort and rep.get('ok'):
            tr.state = 'aborted'
            self.trace_finish(tr)
        self.trace_meta(tr)
        return {'ok': bool(rep.get('ok')), 'msg': rep.get('msg'), 'trace': tr.info()}

    def on_tchunk(self, tid, seq, data):
        tr = self.trace
        if not tr or (tr.id is not None and tid != tr.id):
            log.info('T chunk for trace id %d with no such trace (%d bytes): dropped', tid, len(data))
            return
        if tr.zf is None:
            tr.zf = open(os.path.join(tr.dir, 'trace.lz4.part'), 'wb')
            tr.t_xfer = now_s()
            tr.next_seq = 0
            if tr.state in ('recording', 'stopping'):
                mode = tr.opts.get('mode', 'buffer')
                if mode != 'stream':
                    tr.state = 'transferring'
                    tr.t_stop = tr.t_stop or now_s()
        if seq != tr.next_seq:
            log.warning('trace %s: chunk seq %d, expected %d', tr.name, seq, tr.next_seq)
            tr.seq_err += 1
        tr.next_seq = seq + 1
        tr.zf.write(data)
        tr.zbytes += len(data)
        tr.chunks += 1
        tr.t_xfer_end = now_s()
        if tr.chunks % 4 == 1:
            self.emit('trace', tr.info())

    def on_tend(self, e):
        tr = self.trace
        if not tr:
            log.info('E with no trace: %s', e)
            return
        tr.end = e
        tr.t_xfer_end = now_s()
        tr.t_stop = tr.t_stop or now_s()
        if tr.zf:
            tr.zf.close()
            tr.zf = None
        elif not e.get('zbytes'):
            self.trace_fail(tr, 'phone sent no data: %s' % (e.get('msg') or e))
            return
        if e.get('zbytes') is not None and e['zbytes'] != tr.zbytes:
            self.trace_fail(tr, 'got %d of %d compressed bytes' % (tr.zbytes, e['zbytes']))
            return
        tr.state = 'analyzing'
        self.trace_meta(tr)
        log.info('trace %s: %d bytes in %.1f s (%s MB/s)', tr.name, tr.zbytes, tr.info()['transfer_s'],
                 tr.info()['transfer_mbps'])
        if tr.kind == 'prof' and tr.prof_fut is not None and not tr.prof_fut.done():
            tr.prof_fut.set_result(True)
        else:
            self.queue_analysis(tr)

    def queue_analysis(self, tr):
        self.anq.append(tr)
        self.anev.set()

    def analysis_worker(self, loop):
        while True:
            self.anev.wait()
            self.anev.clear()
            while self.anq:
                tr = self.anq.popleft()
                try:
                    self.analyze(tr)
                    tr.state = 'done'
                except Exception as e:
                    log.exception('analysis of %s', tr.name)
                    tr.state = 'failed'
                    tr.error = 'analysis: %s' % e
                loop.call_soon_threadsafe(self.trace_finish, tr)

    def analyze(self, tr):
        part = os.path.join(tr.dir, 'trace.lz4.part')
        outname = 'prof.bin' if tr.kind == 'prof' else 'trace.swtr'
        out = os.path.join(tr.dir, outname)
        t0 = time.time()
        n, how = lz4_decompress_any(part, out + '.part')
        os.replace(out + '.part', out)
        tr.decomp = {'bytes': n, 'method': how, 's': round(time.time() - t0, 2)}
        exp = (tr.end or {}).get('bytes')
        if exp is not None and exp != n:
            raise LZ4Error('decompressed %d bytes, phone said %d' % (n, exp))
        if self.a.keep_lz4:
            os.replace(part, os.path.join(tr.dir, 'trace.lz4'))
        else:
            os.unlink(part)
        tr.out_file = outname
        log.info('trace %s: %s %d bytes (%s, %.1f s)', tr.name, outname, n, how, tr.decomp['s'])
        tools = os.path.join(self.root, 'tools-claude')
        t1 = time.time()
        if tr.kind == 'kdebug':
            cmd = [sys.executable, '-I', os.path.join(tools, 'sweet-trace.py'), out, '--summary-json',
                   os.path.join(tr.dir, 'summary.json'), '--label', tr.name]
            if tr.opts.get('app'):
                cmd += ['--app', str(tr.opts['app'])]
        else:
            cmd = [sys.executable, '-I', os.path.join(tools, 'sweet-prof.py'), out, 'report', '--top', '30',
                   '--folded', os.path.join(tr.dir, 'prof.folded')]
            k = tr.opts.get('kernel')
            if k and os.path.exists(os.path.join(self.root, k)):
                cmd += ['--kernel', os.path.join(self.root, k)]
        if not os.path.exists(cmd[2]):
            tr.analysis = {'error': 'no %s' % cmd[2]}
            return
        with open(os.path.join(tr.dir, 'report.txt'), 'wb') as f:
            r = subprocess.run(cmd, cwd=self.root, stdout=f, stderr=subprocess.STDOUT, timeout=self.a.analyze_timeout)
        tr.analysis = {'cmd': ' '.join(os.path.basename(c) if i < 3 else c for i, c in enumerate(cmd)),
                       'exit': r.returncode, 's': round(time.time() - t1, 1)}
        if r.returncode:
            tr.error = 'analyzer exit %d (report.txt)' % r.returncode

    async def prof_run(self, tr):
        tr.prof_fut = None
        target = str(tr.opts.get('target') or tr.name)
        hz = int(tr.opts.get('hz', 1000))
        if not re.fullmatch(r'[A-Za-z0-9._-]+', target):
            self.trace_fail(tr, 'bad target %r' % target)
            return
        up = (self.snap.get('phone') or {}).get('uptime_s') or 0
        min_ts = max(0, up - 2)
        f_start, w1 = self.watch(R_PROF_START, min_ts)
        f_err, w2 = self.watch(R_PROF_ERR, min_ts)
        line = 'p prof start %s %d %d' % (target, hz, tr.secs)
        try:
            self.poke(line)
        except OSError as e:
            self.trace_fail(tr, 'poke: %s' % e)
            return
        tr.msg = line
        log.info('prof %s: poke %r', tr.name, line)
        try:
            done, _ = await asyncio.wait([f_start, f_err], timeout=15, return_when=asyncio.FIRST_COMPLETED)
            if f_err in done:
                self.trace_fail(tr, 'kernel: %s' % f_err.result()[2])
                return
            if f_start not in done:
                self.trace_fail(tr, 'no "SWEET PROF: start" line 15 s after the poke (USB poke port 5141 reachable?)')
                return
            ts, m, msg = f_start.result()
            tr.prof = (m.group(6), int(m.group(5)) * 1024)
            tr.state = 'recording'
            tr.t_rec = now_s()
            tr.msg = msg
            self.trace_meta(tr)
            f_done, w3 = self.watch(R_PROF_DONE, ts)
            stop = asyncio.ensure_future(tr.stop_req.wait())
            done, _ = await asyncio.wait([f_done, stop], timeout=tr.secs + 30, return_when=asyncio.FIRST_COMPLETED)
            if stop in done and not f_done.done():
                tr.state = 'stopping'
                self.poke('p prof stop')
                await asyncio.wait([f_done], timeout=15)
            stop.cancel()
            self.unwatch(w3)
            tr.t_stop = now_s()
            if f_done.done():
                _, m, msg = f_done.result()
                pa, ln = m.group(3), int(m.group(4))
            else:
                pa, ln = tr.prof
                log.warning('prof %s: no done line; reading the whole buffer', tr.name)
            ln = min(ln, 64 << 20)
            self.pmem_seq += 1
            tr.id = self.pmem_seq
            tr.state = 'transferring'
            tr.prof_fut = asyncio.get_running_loop().create_future()
            self.trace_meta(tr)
            rep = await self.cmd('pmem %s %d %d' % (pa, ln, tr.id), timeout=20)
            if not rep.get('ok'):
                self.trace_fail(tr, 'pmem: %s' % rep.get('msg'))
                return
            await asyncio.wait_for(tr.prof_fut, 120)
            self.queue_analysis(tr)
        except asyncio.TimeoutError:
            self.trace_fail(tr, 'pmem transfer timed out')
        finally:
            self.unwatch(w1)
            self.unwatch(w2)

    def poke(self, text):
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        try:
            tx.sendto(text.encode(), (self.a.poke_host, self.a.poke_port))
        except OSError:
            tx.sendto(text.encode(), (self.a.poke_bcast, self.a.poke_port))
        finally:
            tx.close()

    def list_traces(self):
        out = []
        try:
            names = sorted(os.listdir(self.tdir), key=lambda n: -os.path.getmtime(os.path.join(self.tdir, n)))
        except OSError:
            names = []
        for n in names[:100]:
            d = os.path.join(self.tdir, n)
            m = read_json(os.path.join(d, 'meta.json'))
            if not m:
                continue
            files = {}
            for f in ('trace.swtr', 'prof.bin', 'summary.json', 'report.txt', 'prof.folded'):
                p = os.path.join(d, f)
                if os.path.exists(p):
                    files[f] = os.path.getsize(p)
            m['files'] = files
            out.append(m)
        return out

    # ---------------------------------------------------------------- speed test
    async def speed_test(self, mb):
        if self.speed is not None:
            return {'ok': False, 'msg': 'a speed test runs'}
        mb = max(1, min(int(mb), 256))
        self.speed = {'bytes': 0, 't_first': None, 't_last': None}
        t0 = time.perf_counter()
        rep = await self.cmd('speed %d' % mb, timeout=30 + mb * 5)
        t1 = time.perf_counter()
        sp, self.speed = self.speed, None
        el = t1 - t0
        res = {'ok': bool(rep.get('ok')), 'mb': mb, 'bytes': sp['bytes'], 'pc_s': round(el, 3),
               'mbps': round(sp['bytes'] / 1e6 / el, 2) if el > 0 else None, 'phone': rep, 'via': self.via,
               'rtt_ms': r1(self.rtt_ms), 't': now_s()}
        self.speed_res = res
        if res['ok'] and res['mbps'] and self.via:
            self.phone_cfg.setdefault('speed', {})[self.via] = {'mbps': res['mbps'], 'mb': mb, 't': res['t'],
                                                               'host': self.host, 'rtt_ms': res['rtt_ms']}
            atomic_json(os.path.join(self.mon, 'phone.json'), self.phone_cfg)
        log.info('speed test %d MiB via %s: %s MB/s (auto prefers %s)', mb, self.via, res['mbps'], self.link_order()[0])
        self.emit('speed', res)
        return res

    # ---------------------------------------------------------------- HTTP
    async def http_client(self, r, w):
        try:
            line = await asyncio.wait_for(r.readline(), 30)
            if not line:
                return
            parts = line.decode('latin-1').split()
            if len(parts) < 2:
                return
            method, target = parts[0].upper(), parts[1]
            hdr = {}
            while True:
                ln = await asyncio.wait_for(r.readline(), 30)
                if ln in (b'\r\n', b'\n', b''):
                    break
                k, _, v = ln.decode('latin-1').partition(':')
                hdr[k.strip().lower()] = v.strip()
            n = int(hdr.get('content-length', 0) or 0)
            body = await r.readexactly(min(n, 1 << 20)) if n else b''
            u = urllib.parse.urlsplit(target)
            q = {k: v[-1] for k, v in urllib.parse.parse_qs(u.query).items()}
            await self.route(method, u.path, q, body, w)
        except (asyncio.TimeoutError, ConnectionError, asyncio.IncompleteReadError):
            pass
        except Exception:
            log.exception('http')
            try:
                self.respond(w, 500, {'ok': False, 'msg': 'internal error'})
            except Exception:
                pass
        finally:
            try:
                await w.drain()
                w.close()
            except Exception:
                pass

    def respond(self, w, code, obj, ctype='application/json'):
        if isinstance(obj, (dict, list)):
            data = json.dumps(obj, default=str).encode()
        elif isinstance(obj, str):
            data = obj.encode()
        else:
            data = obj
        st = {200: 'OK', 400: 'Bad Request', 404: 'Not Found', 405: 'Method Not Allowed', 500: 'Error'}.get(code, 'OK')
        w.write(('HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\n'
                 'Connection: close\r\n\r\n' % (code, st, ctype, len(data))).encode() + data)

    @staticmethod
    def body_json(body):
        if not body:
            return {}
        try:
            v = json.loads(body)
            return v if isinstance(v, dict) else {'value': v}
        except ValueError:
            return {'value': body.decode(errors='replace').strip()}

    async def route(self, method, path, q, body, w):
        J = self.body_json(body) if method == 'POST' else {}
        if path in ('/', '/index.html', '/dashboard.html'):
            try:
                self.respond(w, 200, open(os.path.join(HERE, 'dashboard.html'), 'rb').read(), 'text/html; charset=utf-8')
            except OSError:
                self.respond(w, 404, 'no dashboard.html next to collector.py', 'text/plain')
            return
        if path == '/api/stream':
            await self.sse_client(w)
            return
        if path == '/api/now':
            return self.respond(w, 200, self.now_view())
        if path == '/api/status':
            return self.respond(w, 200, self.status())
        if path == '/api/history':
            secs = float(q.get('secs', 900))
            lo = now_s() - secs
            return self.respond(w, 200, [h for h in self.hist if h['t'] >= lo])
        if path == '/api/klog':
            n = max(1, min(int(q.get('n', 200)), 20000))
            rows = list(self.lines)
            if q.get('grep'):
                try:
                    rx = re.compile(q['grep'], re.I)
                except re.error as e:
                    return self.respond(w, 400, {'ok': False, 'msg': 'bad regex: %s' % e})
                rows = [x for x in rows if rx.search(x[1])]
            return self.respond(w, 200, {'seq': self.line_seq, 'lines': [x[1] for x in rows[-n:]],
                                         'file': self.klog_f and os.path.relpath(self.klog_f.name, self.root)})
        if path == '/api/traces':
            cur = self.trace.info() if self.trace else None
            return self.respond(w, 200, {'current': cur, 'traces': self.list_traces()})
        m = re.fullmatch(r'/api/traces/([A-Za-z0-9._-]+)/(summary\.json|report\.txt|meta\.json|prof\.folded)', path)
        if m:
            p = os.path.join(self.tdir, m.group(1), m.group(2))
            if os.path.isfile(p):
                ct = 'application/json' if p.endswith('.json') else 'text/plain; charset=utf-8'
                return self.respond(w, 200, open(p, 'rb').read(), ct)
            return self.respond(w, 404, {'ok': False, 'msg': 'no such file'})
        if method != 'POST':
            return self.respond(w, 404 if not path.startswith('/api/') else 405, {'ok': False, 'msg': 'not found'})
        if path == '/api/trace/start':
            return self.respond(w, 200, await self.trace_start(J))
        if path == '/api/trace/stop':
            return self.respond(w, 200, await self.trace_stop(bool(J.get('abort'))))
        if path == '/api/cmd':
            c = str(J.get('cmd') or J.get('value') or '').strip()
            if not c:
                return self.respond(w, 400, {'ok': False, 'msg': 'cmd'})
            return self.respond(w, 200, await self.cmd(c, timeout=float(J.get('timeout', 15))))
        if path == '/api/link':
            v = str(J.get('link') or J.get('value') or '')
            if v not in ('usb', 'wifi', 'auto'):
                return self.respond(w, 400, {'ok': False, 'msg': 'link: usb wifi auto'})
            old = self.cfg.get('link')
            self.cfg['link'] = v
            self.save_cfg()
            if self.connected and self.via != v and v != 'auto' and self.writer:
                self.writer.close()
            self.kick.set()
            log.info('link %s -> %s', old, v)
            return self.respond(w, 200, {'ok': True, 'msg': 'link %s' % v, 'link': self.link_info()})
        if path == '/api/speed':
            return self.respond(w, 200, await self.speed_test(J.get('mb') or J.get('value') or 16))
        if path == '/api/frames':
            v = J.get('on', J.get('value'))
            on = v in (True, 1, 'on', '1', 'true')
            self.cfg['frames'] = on
            self.save_cfg()
            rep = await self.cmd('frames %s' % ('on' if on else 'off')) if self.authed else {'ok': True, 'msg':
                                                                                             'saved; sent on connect'}
            if not on:
                self.frames_last = None
            return self.respond(w, 200, rep)
        if path == '/api/klog-pa':
            pa = str(J.get('pa') or J.get('value') or '')
            if pa in ('', 'auto', 'none'):
                self.cfg.pop('klog_pa', None)
            elif not re.fullmatch(r'0x[0-9a-fA-F]{6,12}', pa):
                return self.respond(w, 400, {'ok': False, 'msg': 'PA like 0x101d0ef08 (or auto)'})
            else:
                self.cfg['klog_pa'] = pa
            self.save_cfg()
            if self.authed:
                await self.start_klog()
            return self.respond(w, 200, {'ok': True, 'msg': self.klog_ok or 'saved', 'candidates': self.pa_candidates()})
        if path == '/api/rate':
            ms = max(200, min(int(J.get('ms') or J.get('value') or 1000), 10000))
            self.cfg['rate_ms'] = ms
            self.cfg['top_every'] = int(J.get('top_every') or self.cfg['top_every'])
            self.save_cfg()
            return self.respond(w, 200, await self.cmd('rate %d %d' % (ms, self.cfg['top_every'])))
        return self.respond(w, 404, {'ok': False, 'msg': 'not found'})

    def status(self):
        return {'collector': {'pid': os.getpid(), 'up_s': round(now_s() - self.t0), 'root': self.root,
                              'http': '%s:%d' % (self.a.http_host, self.a.http_port), 'sse_clients': len(self.sse),
                              'history': len(self.hist)},
                'link': self.link_info(), 'hello': self.hello, 'config': self.cfg,
                'klog': {'status': self.klog_ok, 'pos': self.klog_pos, 'lost': self.klog_lost,
                         'file': self.klog_f and os.path.relpath(self.klog_f.name, self.root)},
                'trace': self.trace.info() if self.trace else None,
                'last_trace': self.traces_done[0] if self.traces_done else None, 'speed': self.speed_res,
                'pa_candidates': self.pa_candidates()}

    async def sse_client(self, w):
        w.write(b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n'
                b'Connection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n')
        q = asyncio.Queue(maxsize=500)
        self.sse.add(q)
        try:
            init = {'snap': self.snap, 'link': self.link_info(), 'hello': self.hello,
                    'trace': self.trace.info() if self.trace else None}
            w.write(('retry: 2000\nevent: init\ndata: %s\n\n' % json.dumps(init, default=str)).encode())
            await w.drain()
            while q in self.sse:
                try:
                    msg = await asyncio.wait_for(q.get(), 15)
                except asyncio.TimeoutError:
                    msg = b': keepalive\n\n'
                w.write(msg)
                await w.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            self.sse.discard(q)

    # ---------------------------------------------------------------- main
    async def run(self):
        loop = asyncio.get_running_loop()
        threading.Thread(target=self.analysis_worker, args=(loop,), daemon=True).start()
        try:
            srv = await asyncio.start_server(self.http_client, self.a.http_host, self.a.http_port)
        except OSError as e:
            log.error('cannot listen on %s:%d: %s (another collector running?)', self.a.http_host, self.a.http_port, e)
            print('collector: cannot listen on %s:%d: %s (another collector running?)' %
                  (self.a.http_host, self.a.http_port, e), file=sys.stderr)
            return 1
        log.info('collector pid %d: http://%s:%d/  root %s  link %s', os.getpid(), self.a.http_host, self.a.http_port,
                 self.root, self.cfg['link'])
        atomic_json(os.path.join(self.mon, 'collector.json'), {'pid': os.getpid(), 'started': now_s(),
                                                               'http': 'http://%s:%d/' % (self.a.http_host,
                                                                                          self.a.http_port)})
        async with srv:
            await self.link_loop()


# ---------------------------------------------------------------- ctl (the phone agent's `mon ...`)
def ctl(argv, api):
    def call(path, data=None, timeout=30):
        req = urllib.request.Request(api + path, data=json.dumps(data).encode() if data is not None else None,
                                     headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            try:
                return json.loads(e.read())
            except ValueError:
                return {'ok': False, 'msg': 'HTTP %d' % e.code}
        except (urllib.error.URLError, OSError) as e:
            print('collector not answering at %s (%s): mon-start' % (api, getattr(e, 'reason', e)))
            sys.exit(2)

    def out(r):
        print(json.dumps(r, indent=1, default=str))
        return 0 if (not isinstance(r, dict) or r.get('ok', True)) else 1

    if not argv:
        print(__doc__)
        return 1
    c, rest = argv[0], argv[1:]
    if c == 'status':
        s = call('/api/status')
        L = s['link']
        print('collector pid %s up %s s, link %s via %s %s: %s, rtt %s ms, reconnects %s' % (
            s['collector']['pid'], s['collector']['up_s'], L['mode'], L['via'], L['host'],
            'connected' if L['authed'] else L['msg'], L['rtt_ms'], L['reconnects']))
        print('klog: %s, file %s, pos %s, lost %s' % (s['klog']['status'], s['klog']['file'], s['klog']['pos'],
                                                    s['klog']['lost']))
        if s.get('trace'):
            print('trace:', json.dumps(s['trace'], default=str))
        elif s.get('last_trace'):
            t = s['last_trace']
            print('last trace: %s %s %s %s' % (t['name'], t['kind'], t['state'], t.get('error') or ''))
        if s.get('speed'):
            print('last speed test: %s MB/s via %s' % (s['speed']['mbps'], s['speed']['via']))
        return 0
    if c == 'snap':
        return snap_text(call('/api/now'))
    if c == 'trace':
        if not rest:
            print('mon trace NAME [kdebug|prof] [SECS] [k=v ...]')
            return 1
        req = {'name': rest[0], 'kind': 'kdebug', 'opts': {}}
        for x in rest[1:]:
            if x in ('kdebug', 'prof'):
                req['kind'] = x
            elif x.isdigit():
                req['secs'] = int(x)
            elif '=' in x:
                k, v = x.split('=', 1)
                req['opts'][k] = v
            else:
                print('bad argument %r' % x)
                return 1
        return out(call('/api/trace/start', req))
    if c == 'stop':
        return out(call('/api/trace/stop', {'abort': 'abort' in rest}))
    if c == 'traces':
        r = call('/api/traces')
        if r.get('current'):
            print('current:', json.dumps(r['current'], default=str))
        for t in r['traces'][:int(rest[0]) if rest else 10]:
            fs = ' '.join('%s %.2f MB' % (k, v / 1e6) for k, v in t.get('files', {}).items())
            print('%-28s %-6s %-9s %6s s %8s MB/s  %s  %s' % (t['dir'], t['kind'], t['state'], t.get('transfer_s'),
                                                         t.get('transfer_mbps'), fs, t.get('error') or ''))
        return 0
    if c == 'wait':
        lim = time.time() + (float(rest[0]) if rest else 150)
        while time.time() < lim:
            r = call('/api/traces')
            if not r.get('current'):
                t = r['traces'][0] if r['traces'] else None
                print(json.dumps(t, indent=1, default=str) if t else 'no traces')
                return 0 if t and t['state'] == 'done' else 1
            time.sleep(2)
        print('still running:', json.dumps(call('/api/traces')['current'], default=str))
        return 1
    if c == 'link':
        return out(call('/api/link', {'link': rest[0] if rest else ''}))
    if c == 'speed':
        return out(call('/api/speed', {'mb': int(rest[0]) if rest else 16}, timeout=600))
    if c == 'frames':
        return out(call('/api/frames', {'on': (rest[0] if rest else 'on') == 'on'}))
    if c == 'klog-pa':
        return out(call('/api/klog-pa', {'pa': rest[0] if rest else 'auto'}))
    if c == 'rate':
        return out(call('/api/rate', {'ms': int(rest[0]) if rest else 1000}))
    if c == 'cmd':
        return out(call('/api/cmd', {'cmd': ' '.join(rest)}))
    print('unknown: %s' % c)
    return 1


def snap_text(s):
    if not s.get('cpu'):
        print('no sample yet; link: %s' % json.dumps(s.get('link'), default=str))
        return 1
    L, P = s['link'], s['phone']
    up = int(P.get('uptime_s') or 0)
    print('%s  link %s %s rtt %s ms  up %d:%02d:%02d  daemon cpu %s%% rss %s MB' % (
        s['time'], L['via'], L['host'], L['rtt_ms'], up // 3600, up // 60 % 60, up % 60, s['self']['cpu_pct'],
        s['self']['rss_mb']))
    for h in s.get('hot') or []:
        print('  * ' + h)
    t = s['temp']
    print('temp (%s): %s' % (s.get('temp_source'), ' '.join('%s %s' % kv for kv in t.items())))
    th = s['thermal']
    print('thermal level %s%s' % (th['level'], ' caps %s' % th['cap_mhz'] if th.get('cap_mhz') else ''))
    c = s['cpu']
    b = c['busy']
    print('cpu busy %s | %s | %s %%  avg %s  load %s' % (' '.join('%.0f' % x for x in b[:6] if x is not None),
                                                         b[6] if len(b) > 6 else '-', b[7] if len(b) > 7 else '-',
                                                         c['avg'], c.get('load')))
    print('MHz silver %s gold %s prime %s (klog %s s old)' % (c['clusters']['silver']['mhz'],
                                                             c['clusters']['gold']['mhz'], c['clusters']['prime']['mhz'],
                                                             c.get('cpufreq_age_s')))
    g = s.get('gpu')
    if g:
        print('gpu %s%% busy %s ms, %s submits (%s missed): %s' % (g['busy_pct'], g['busy_ms'], g['submits'],
                                                                 g['missed'], ', '.join('%s %s/%sms' % (
                                                                     o['name'], o['submits'], o['ms'])
                                                                                        for o in g['owners'])))
    if s.get('fb'):
        f = s['fb']
        print('fb 5s: shown %s (%.1f fps) dropped %s p50 %s p95 %s ms hz %s' % (f['shown'], f['fps'], f['dropped'],
                                                                               f['p50_ms'], f['p95_ms'], f['hz']))
    if s.get('frames'):
        print('frames: %s' % json.dumps({k: v for k, v in s['frames'].items() if not k.startswith('_')}))
    bt = s.get('battery')
    if bt:
        print('battery %s%% %s mA %s mV ext %s chg %s' % (bt['pct'], bt['ma'], bt['mv'], bt['ext'], bt['chg']))
    m = s['mem']
    print('mem free %s MB used %s (wired %s, compressed %s) pageins %s/s faults %s/s' % (
        m['free_mb'], m['used_mb'], m['wired_mb'], m['compressed_mb'], m['pageins_s'], m['faults_s']))
    print('top cpu:     ' + ', '.join('%s[%s] %s%%' % (p['name'], p['pid'], p['cpu_pct']) for p in s['procs']['by_cpu'][:8]))
    print('top wakeups: ' + ', '.join('%s %s/s' % (p['name'], p['wakeups_s']) for p in s['procs']['by_wakeups'][:5]))
    k = s['klog']
    print('klog %s B/s (kernel), rx %s B/s; %s; top: %s' % (k['bps_kernel'], k['bps_rx'], k['file'], ', '.join(
        '%s %s B/s' % (x['tag'], x['bps']) for x in k['top_tags'][:5])))
    for cr in s.get('crashes', [])[:3]:
        print('crash: [%.1f] %s' % (cr['ts'], cr['line']))
    if s.get('trace'):
        tr = s['trace']
        print('trace %s %s %s %s' % (tr['name'], tr['kind'], tr['state'], tr.get('error') or ''))
    return 0


def make_key(root, force):
    p = os.path.join(root, 'agent', 'sweetmon.key')
    if os.path.exists(p) and not force:
        print('%s exists (--force to replace)' % p)
        return 0
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w') as f:
        f.write(secrets.token_hex(16) + '\n')
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass
    print('wrote %s (install it on the phone: mon install)' % p)
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'ctl':
        api = os.environ.get('SWEETMON_API', 'http://127.0.0.1:8765')
        return ctl(sys.argv[2:], api.rstrip('/'))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default=os.environ.get('SWEETMON_ROOT', DEFAULT_ROOT))
    ap.add_argument('--link', choices=('auto', 'usb', 'wifi'), help='saved in logs/mon/config.json')
    ap.add_argument('--http-host', default='127.0.0.1')
    ap.add_argument('--http-port', type=int, default=8765)
    ap.add_argument('--usb-host', default=USB_HOST)
    ap.add_argument('--wifi-host', help='override the Wi-Fi address learned from the phone')
    ap.add_argument('--port', type=int, default=PORT)
    ap.add_argument('--ssh-port', type=int, default=22, help='checked before starting the daemon over ssh')
    ap.add_argument('--ssh-bin', default='ssh')
    ap.add_argument('--no-autostart', action='store_true')
    ap.add_argument('--autostart-every', type=float, default=30)
    ap.add_argument('--poke-host', default=USB_HOST)
    ap.add_argument('--poke-bcast', default='192.168.7.255')
    ap.add_argument('--poke-port', type=int, default=5141)
    ap.add_argument('--retry', type=float, default=2.0)
    ap.add_argument('--connect-timeout', type=float, default=2.0)
    ap.add_argument('--ping-every', type=float, default=5.0)
    ap.add_argument('--usb-probe-every', type=float, default=20.0, help='auto: probe the faster link this often')
    ap.add_argument('--history-secs', type=float, default=3600)
    ap.add_argument('--trace-grace', type=float, default=60)
    ap.add_argument('--analyze-timeout', type=float, default=900)
    ap.add_argument('--keep-lz4', action='store_true')
    ap.add_argument('--log', help='default ROOT/logs/mon/collector.log ("-" = stderr)')
    ap.add_argument('-v', '--verbose', action='store_true')
    ap.add_argument('--make-key', action='store_true')
    ap.add_argument('--force', action='store_true')
    a = ap.parse_args()
    if a.make_key:
        return make_key(a.root, a.force)
    os.makedirs(os.path.join(a.root, 'logs', 'mon'), exist_ok=True)
    lp = a.log or os.path.join(a.root, 'logs', 'mon', 'collector.log')
    h = logging.StreamHandler(sys.stderr) if lp == '-' else logging.FileHandler(lp)
    h.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s', '%m-%d %H:%M:%S'))
    log.addHandler(h)
    log.setLevel(logging.DEBUG if a.verbose else logging.INFO)
    try:
        return asyncio.run(Collector(a).run())
    except KeyboardInterrupt:
        return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
