#!/usr/bin/env python3
"""exp-run.py PLAN [--dry-run] [--out DIR] [--analyze-only DIR]: run a whole A/B experiment on the phone with no LLM in
the loop (u-lab). Runs in WSL as the user (the phone agent's `exp PLAN` action starts it in the background; by hand:
python3 tools-claude/exp-run.py agent/exp/NAME.plan). Needs the USB network (192.168.7.2), dropbear with the key
~/.ssh/redfin-claude, the agent's live log (logs/live-*.txt, newest) and sweettrace from ws-u-lab (-f -z; an older one
works too: full traces, reduced on the PC).

Per run (variant x scene x repeat, in the plan's order):
  variant switch  /var/local/mtl2-env = base + variant lines (ssh), psx -k backboardd, wait for backboardd's
                  "native-metal: prewarm: N pipelines in X ms" and SpringBoard's (live log; no fixed sleeps), check the
                  "env K=V" lines backboardd printed against the plan, settle
  guards          temperature (latest SWEET THERMAL line: max of silver/gold/prime/cpuss/gpu) >= hot: pause until
                  <= cool; battery (SWEET BATTERY ... shown N%) <= stop_battery: stop; display: keep-alive tap, p disp,
                  power key only when the display is off
  scene           settings: Preferences killed, home x2, page 2, tap the Settings icon, checked with psx
                  pages: home x2;  scroll: the app already open (plan `nav` lines first)
  trace           labtrace.sh on the phone (sweettrace -t 8 -d 1 -f -z + the scene's flings, sent on the phone)
  pull            ssh cat (gzip) -> OUT/ID.swtr.gz, size checked, removed on the phone; fallback flame-files.py get
  analysis        in the background while the phone goes on: gunzip, (swtr-reduce.py if the trace is full),
                  sweet-trace.py --summary-json, frames-export.py -> one row of OUT/summary.tsv
At the end: the original mtl2-env back and backboardd restarted (restore no: left as the last variant), then the A/B
table (median per variant and scene, difference to the first variant) -> OUT/ab.txt and stdout.

Plan file (one directive per line, # comments):
  name ubwc-test              output dir logs/exp-<name>-<MMDD-HHMM> (default: the plan file's name)
  scenes settings pages       settings | pages | scroll | idle  (default settings pages)
  repeats 3                   rounds (default 3)
  order abba                  abba (A B B A A B ..., default) | abab | blocks (A A A B B B)
  restart always              always (default: every run starts from a fresh backboardd) | switch (only when the
                              env changes)
  settle 4                    s after SpringBoard's prewarm (default 4)
  hot 62 / cool 57            thermal pause above hot until cool (C);  stop_battery 25 (%)
  trace -t 8                  extra sweettrace flags (after -f -z)
  keep_swtr no                yes: keep the decompressed .swtr next to the .gz (default no: ~50 MB each)
  restore yes                 put the original mtl2-env back at the end (default yes)
  base                        the lines that follow (KEY=VALUE) are in every variant's env
    TU_DEBUG=gmem
  variant A                   a variant: its KEY=VALUE lines override base; "-KEY" drops a base key
    SWEET_UBWC=1
  variant B
    SWEET_UBWC=0
    live SWEET_CPUFAST=0x1    (in a variant) a knob the ws-u-lab frontend switches without a restart (SWEET_CPUFAST,
                              SWEET_ENCSTAT, SWEET_FNSTAT, SWEET_ENC_SLOW_MS) -> /var/local/mtl2-live; with `restart switch`
                              and the same env lines, such variants switch in ~1 s (checked: backboardd's "live:" line)
  nav swipe 540 1900 540 600 120   (scroll scene) pokes sent before the trace, one per line (sleep N: wait)
  app Preferences             (scroll scene) the process sweet-trace.py follows (default Preferences)
  settings_xy 914 290         the Settings icon on home page 2;  settings_wait 3 (s after the tap)
"""
import argparse
import gzip
import json
import os
import re
import shlex
import shutil
import socket
import statistics
import subprocess
import sys
import time

P = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(P, 'tools-claude')
PHONE = os.environ.get('PHONE_IP', '192.168.7.2')
KEY = os.path.expanduser('~/.ssh/redfin-claude')
SSH = ['ssh', '-i', KEY, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=5',
       '-o', 'LogLevel=ERROR', '-o', 'BatchMode=yes', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=300',
       '-o', 'ControlPath=/tmp/exp-run-ssh-%r@%h', 'root@' + PHONE]
ENV_PATH = '/var/local/mtl2-env'
LIVE_PATH = '/var/local/mtl2-live'      # ws-u-lab frontend: knobs switched without a restart


class Stop(Exception):
    pass


# ---------------------------------------------------------------- plan
def parse_plan(path):
    plan = dict(name=os.path.splitext(os.path.basename(path))[0], scenes=['settings', 'pages'], repeats=3, order='abba',
                restart='always', settle=4.0, hot=62.0, cool=57.0, stop_battery=25, trace=[], keep_swtr=False,
                restore=True, base=[], variants=[], nav=[], settings_xy='914 290', settings_wait=3.0,
                app='Preferences')
    cur = None
    for n, raw in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
        line = raw.split('#', 1)[0].strip() if not raw.lstrip().startswith('-') else raw.strip()
        if not line:
            continue
        word, _, rest = line.partition(' ')
        rest = rest.strip()
        if re.match(r'^-?[A-Za-z_][A-Za-z0-9_]*(=|$)', line) and ('=' in line or line.startswith('-')) and cur is not None:
            cur.append(line)
            continue
        if word == 'live' and plan['variants'] and cur is plan['variants'][-1]['env']:
            if not re.match(r'^(SWEET_CPUFAST|SWEET_ENCSTAT|SWEET_FNSTAT|SWEET_ENC_SLOW_MS)=\S*$', rest):
                raise SystemExit(f'{path}:{n}: live KEY=VALUE, KEY one of SWEET_CPUFAST SWEET_ENCSTAT SWEET_FNSTAT '
                                 'SWEET_ENC_SLOW_MS (ws-u-lab frontend)')
            plan['variants'][-1]['live'].append(rest)
            continue
        if word == 'base':
            cur = plan['base']
        elif word == 'variant':
            if not re.match(r'^[A-Za-z0-9_.-]+$', rest):
                raise SystemExit(f'{path}:{n}: variant name: letters, digits, _ . -')
            v = dict(name=rest, env=[], live=[])
            plan['variants'].append(v)
            cur = v['env']
        elif word == 'scenes':
            plan['scenes'] = rest.split()
            bad = [s for s in plan['scenes'] if s not in ('settings', 'pages', 'scroll', 'idle')]
            if bad:
                raise SystemExit(f'{path}:{n}: unknown scene {bad}')
        elif word in ('repeats', 'stop_battery'):
            plan[word] = int(rest)
        elif word in ('settle', 'hot', 'cool', 'settings_wait'):
            plan[word] = float(rest)
        elif word == 'order':
            if rest not in ('abba', 'abab', 'blocks'):
                raise SystemExit(f'{path}:{n}: order abba | abab | blocks')
            plan['order'] = rest
        elif word == 'restart':
            if rest not in ('always', 'switch'):
                raise SystemExit(f'{path}:{n}: restart always | switch')
            plan['restart'] = rest
        elif word in ('name', 'settings_xy', 'app'):
            plan[word] = rest
        elif word == 'trace':
            plan['trace'] = shlex.split(rest)
            if any(not re.match(r'^[A-Za-z0-9,./_-]+$', a) for a in plan['trace']):
                raise SystemExit(f'{path}:{n}: trace flags: plain words only')
        elif word in ('keep_swtr', 'restore'):
            plan[word] = rest.lower() in ('1', 'yes', 'true', 'on')
        elif word == 'nav':
            plan['nav'].append(rest)
        else:
            raise SystemExit(f'{path}:{n}: unknown directive {word!r}')
    if not plan['variants']:
        raise SystemExit(f'{path}: no variant')
    for v in plan['variants']:
        v['text'] = env_text(plan['base'], v['env'])
        v['live_text'] = ''.join(l + '\n' for l in v['live'])
    plan['uses_live'] = any(v['live'] for v in plan['variants'])
    return plan


def env_text(base, var):
    kv = {}
    for line in base + var:
        if line.startswith('-'):
            kv.pop(line[1:].split('=', 1)[0], None)
            continue
        k, _, val = line.partition('=')
        kv.pop(k, None)
        kv[k] = val
    return ''.join(f'{k}={v}\n' for k, v in kv.items())


def schedule(plan):
    vs = plan['variants']
    runs = []
    for r in range(plan['repeats']):
        if plan['order'] == 'abab':
            seq = vs
        elif plan['order'] == 'abba':
            seq = vs if r % 2 == 0 else vs[::-1]
        else:
            seq = None
        if seq is not None:
            runs += [(v, r + 1) for v in seq]
    if plan['order'] == 'blocks':
        runs = [(v, r + 1) for v in vs for r in range(plan['repeats'])]
    return runs


# ---------------------------------------------------------------- phone I/O
def ssh(cmd, inp=None, timeout=60, check=True):
    r = subprocess.run(SSH + [cmd], input=inp, capture_output=True, timeout=timeout)
    if check and r.returncode != 0:
        raise Stop(f'ssh {cmd!r}: exit {r.returncode}: {r.stderr.decode(errors="replace").strip()[:300]}')
    return r.stdout.decode(errors='replace')


_tx = None


def poke(text):
    global _tx
    if _tx is None:
        _tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        _tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        _tx.sendto(text.encode(), (PHONE, 5141))
    except OSError:
        _tx.sendto(text.encode(), ('192.168.7.255', 5141))


class Live:
    """the phone agent's live kernel log (UDP 5140 -> logs/live-*.txt, the newest file)"""

    def __init__(self):
        self.path = self.newest()
        if self.path is None:
            raise Stop('no logs/live-*.txt: start the phone agent (its live log) first')

    @staticmethod
    def newest():
        d = os.path.join(P, 'logs')
        fs = [os.path.join(d, f) for f in os.listdir(d) if f.startswith('live-') and f.endswith('.txt')]
        return max(fs, key=os.path.getmtime) if fs else None

    def mark(self):
        n = self.newest()
        if n != self.path:
            self.path = n
        return (self.path, os.path.getsize(self.path))

    def since(self, mark):
        path, off = mark
        n = self.newest()
        out = ''
        if path != n:         # the agent restarted its recorder: the rest of the old file, then the new one
            with open(path, 'rb') as f:
                f.seek(off)
                out = f.read().decode(errors='replace')
            path, off = n, 0
            self.path = n
        with open(path, 'rb') as f:
            f.seek(off)
            out += f.read().decode(errors='replace')
        return out.replace('\0', '')

    def tail(self, nbytes=400000):
        path = self.newest()
        sz = os.path.getsize(path)
        with open(path, 'rb') as f:
            f.seek(max(0, sz - nbytes))
            return f.read().decode(errors='replace').replace('\0', '')

    def wait(self, rx, mark, timeout, poll=0.25):
        rx = re.compile(rx)
        end = time.time() + timeout
        while True:
            m = None
            for m in rx.finditer(self.since(mark)):
                pass
            if m is not None:
                return m
            if time.time() > end:
                return None
            time.sleep(poll)

    def age(self):
        return time.time() - os.path.getmtime(self.newest())


# ---------------------------------------------------------------- runner
class Runner:
    def __init__(self, plan, out, dry):
        self.plan, self.out, self.dry = plan, out, dry
        self.log_f = open(os.path.join(out, 'run.log'), 'a') if not dry else None
        self.t0 = time.time()
        self.pending = []       # analysis processes
        self.rows = []
        self.cur_env = None
        self.full_trace = False
        self.live = None

    def log(self, msg):
        line = f'{time.strftime("%H:%M:%S")} +{time.time() - self.t0:6.1f}s {msg}'
        print(line, flush=True)
        if self.log_f:
            self.log_f.write(line + '\n')
            self.log_f.flush()

    def check_stop(self):
        if os.path.exists(os.path.join(self.out, 'STOP')):
            raise Stop('STOP file')

    # guards
    def thermal_battery(self):
        t = self.live.tail()
        temp = batt = None
        for m in re.finditer(r'SWEET THERMAL: silver ([\d.]+) gold ([\d.]+) prime ([\d.]+) cpuss ([\d.]+) gpu ([\d.]+)', t):
            temp = max(float(x) for x in m.groups())
        for m in re.finditer(r'SWEET BATTERY: [^\n]*shown (\d+)%', t):
            batt = int(m.group(1))
        return temp, batt

    def guard(self):
        p = self.plan
        waited = 0
        while True:
            self.check_stop()
            temp, batt = self.thermal_battery()
            if batt is not None and batt <= p['stop_battery']:
                raise Stop(f'battery {batt}% <= {p["stop_battery"]}%: stop (park the phone in fastboot to charge)')
            if temp is None or temp < (p['hot'] if waited == 0 else p['cool']):
                if waited:
                    self.log(f'guard: {temp} C, going on after {waited} s')
                if self.live.age() > 30:
                    self.log(f'guard: WARNING live log idle for {self.live.age():.0f} s (no fresh THERMAL lines)')
                return temp, batt
            if waited == 0:
                self.log(f'guard: {temp} C >= {p["hot"]} C: pausing until <= {p["cool"]} C')
            if waited > 900:
                raise Stop(f'still {temp} C after 15 min')
            time.sleep(10)
            waited += 10

    def disp(self):
        m0 = self.live.mark()
        poke('p disp')
        m = self.live.wait(r'SWEET FB: display (on|off)', m0, 3)
        return m.group(1) if m else 'unknown'

    def ensure_display(self):
        poke('tap 540 40')      # keep-alive: resets the idle timer, does nothing on the lock or home screen
        time.sleep(0.4)
        d = self.disp()
        if d == 'off':
            self.log('display off: power key')
            poke('key 0 100')
            time.sleep(1.5)
            d = self.disp()
            if d == 'off':
                raise Stop('display still off after the power key')
            d = 'woken'
        return d

    def home(self):
        poke('swipe 540 2335 540 1500 120')
        time.sleep(1.2)

    def unlock_home(self):
        poke('swipe 540 2335 540 900 200')      # lock screen up (on the home screen: a home gesture)
        time.sleep(1.5)
        self.home()
        self.home()

    # variant switch
    def apply_env(self, v):
        text = v['text']
        ssh(f'cat > {ENV_PATH}', inp=text.encode())
        back = ssh(f'cat {ENV_PATH}')
        if back != text:
            raise Stop(f'{ENV_PATH} reads back different:\n{back}')
        m0 = self.live.mark()
        t = time.time()
        ssh('/var/local/bin/psx -k backboardd', check=False)
        m = self.live.wait(r'MTL2\[(\d+) backboardd\]: native-metal: prewarm: (\d+) pipelines in (\d+) ms', m0, 120)
        if m is None:
            dev = self.live.wait(r'MTL2\[(\d+) backboardd\]: device ', m0, 5)
            self.log('restart: no prewarm line in 120 s' + (' (device opened: SWEET_PREWARM=0?)' if dev else ''))
            if dev is None:
                raise Stop('backboardd did not come back (no MTL2 device line)')
            pid, pipes, pms = dev.group(1), '', ''
            time.sleep(10)
        else:
            pid, pipes, pms = m.groups()
            sb = self.live.wait(r'MTL2\[\d+ SpringBoard\]: native-metal: prewarm: \d+ pipelines in \d+ ms', m0, 60)
            if sb is None:
                self.log('restart: no SpringBoard prewarm line in 60 s')
        took = time.time() - t
        got = {}
        for e in re.finditer(r'MTL2\[' + pid + r' backboardd\]: env ([^=\s]+)=([^\n]*)', self.live.since(m0)):
            got[e.group(1)] = e.group(2).strip()
        want = dict(l.split('=', 1) for l in text.splitlines() if '=' in l)
        bad = [k for k in want if got.get(k) != want[k]]
        self.log(f'restart: backboardd {pid}, prewarm {pipes} pipelines in {pms} ms, ready after {took:.1f} s'
                 + (f'; ENV MISMATCH {bad}' if bad else '; env ok'))
        time.sleep(self.plan['settle'])
        self.cur_env = text
        return dict(bb_pid=pid, prewarm_pipes=pipes, prewarm_ms=pms, restart_s=round(took, 1), env_ok=int(not bad))

    # scenes
    def open_settings(self):
        ssh('/var/local/bin/psx -k Preferences', check=False)
        for attempt in (1, 2):
            self.home()
            self.home()
            poke('swipe 900 1200 180 1200 250')
            time.sleep(1.2 if attempt == 1 else 1.5)
            poke('tap ' + self.plan['settings_xy'])
            time.sleep(self.plan['settings_wait'])
            if 'Preferences' in ssh('/var/local/bin/psx Preferences', check=False):
                return 'ok' if attempt == 1 else 'retry'
        raise Stop('Settings did not open (psx shows no Preferences)')

    def scene(self, s):
        if s == 'settings':
            return self.open_settings(), 'settings', 'Preferences'
        if s == 'pages':
            self.home()
            self.home()
            return 'home', 'pages', 'SpringBoard'
        if s == 'scroll':
            for c in self.plan['nav']:
                if c.startswith('sleep '):
                    time.sleep(float(c.split()[1]))
                else:
                    poke(c)
                    time.sleep(0.3)
            return 'nav', 'scroll', self.plan['app']
        return 'idle', 'idle', 'SpringBoard'

    def trace(self, tid, mode):
        remote = f'/var/tmp/lab-{tid}.swtr' + ('' if self.full_trace else '.gz')
        flags = ([] if self.full_trace else ['-f', '-z']) + self.plan['trace']
        t = time.time()
        out = ssh(f'/bin/sh /var/tmp/labtrace.sh {remote} {mode} ' + ' '.join(flags), timeout=90)
        tt = time.time() - t
        m = re.search(r'sweettrace: (\d+) events in', out)
        if m is None:
            raise Stop(f'sweettrace failed:\n{out[-600:]}')
        if 'WRAPPED' in out or 'dropped' in out:
            self.log('trace: WARNING ' + out.strip().splitlines()[-1])
        local = os.path.join(self.out, os.path.basename(remote))
        t = time.time()
        size = int(ssh(f'toybox stat -c %s {remote}').strip())
        r = subprocess.run(SSH + [f'cat {remote}'], stdout=open(local + '.part', 'wb'), stderr=subprocess.PIPE, timeout=600)
        how = 'ssh'
        if r.returncode != 0 or os.path.getsize(local + '.part') != size:
            self.log(f'pull: ssh gave {os.path.getsize(local + ".part")} of {size} bytes: file server instead')
            how = 'files'
            subprocess.run([sys.executable, '-I', os.path.join(os.path.expanduser(os.environ.get('REPO', '~/ios-redfin')),
                            'tools', 'flame-files.py'), 'get', remote, local + '.part'], timeout=900, check=False)
            if os.path.getsize(local + '.part') != size:
                raise Stop('pull failed (size mismatch)')
        os.replace(local + '.part', local)
        pt = time.time() - t
        ssh(f'rm -f {remote} {remote}.log', check=False)
        self.log(f'trace {tid}: {m.group(1)} events, {tt:.1f} s on the phone; pull {size / 1e6:.1f} MB in {pt:.1f} s '
                 f'({size / 1e6 / max(pt, 1e-3):.1f} MB/s, {how})')
        return local, dict(trace_mb=round(size / 1e6, 2), trace_s=round(tt, 1), pull_s=round(pt, 1), pull=how)

    # analysis (background)
    def analyze_start(self, local, tid, app, row):
        sh = os.path.join(self.out, f'{tid}.analyze.sh')
        q = shlex.quote
        swtr = local[:-3] if local.endswith('.gz') else local
        steps = []
        if local.endswith('.gz'):
            steps.append(f'gzip -dc {q(local)} > {q(swtr)}')
        a = swtr
        if self.full_trace:
            a = swtr[:-5] + '.red'
            steps.append(f'python3 -I {q(TOOLS)}/swtr-reduce.py {q(swtr)} {q(a)}')
        rep = os.path.join(self.out, f'{tid}-report.txt')
        js = os.path.join(self.out, f'{tid}.json')
        steps.append(f'python3 -I {q(TOOLS)}/sweet-trace.py {q(a)} --app {app} --frames 3000 --summary-json {q(js)} '
                     f'--label {tid} > {q(rep)} 2>&1')
        steps.append(f'python3 -I {q(TOOLS)}/frames-export.py {q(os.path.join(self.out, "frames-" + tid + ".json"))} '
                     f'{tid}={q(rep)} >/dev/null 2>&1')
        if not self.plan['keep_swtr'] and local.endswith('.gz'):
            steps.append(f'rm -f {q(swtr)}')
        if self.full_trace and not self.plan['keep_swtr']:
            steps.append(f'rm -f {q(swtr)}')       # the .red stays
        open(sh, 'w').write('set -e\n' + '\n'.join(steps) + '\n')
        self.pending.append((subprocess.Popen(['bash', sh], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT), js, row))
        self.reap(block=False, limit=2)

    def reap(self, block, limit=0):
        """collect finished analyses; block: all of them; else wait for the oldest while more than limit run"""
        while self.pending:
            running = [it for it in self.pending if it[0].poll() is None]
            done = [it for it in self.pending if it[0].poll() is not None]
            if not done:
                if not block and len(running) <= limit:
                    return
                done = [self.pending[0]]
            for item in done:
                proc, js, row = item
                try:
                    proc.wait(timeout=600)
                except subprocess.TimeoutExpired:
                    proc.kill()
                self.pending.remove(item)
                row.update(metrics(js))
                self.rows.append(row)
                write_tsv(self.out, self.rows)
                self.log(f'analysis {row["id"]}: ' + (f'frames {row.get("frames")}, interval p50 {row.get("int_p50")} ms, '
                         f'1v {row.get("v1_swipe")} 2v {row.get("v2_swipe")} 3v+ {row.get("v3p_swipe")}, '
                         f'GPU p50 {row.get("gpu_p50")} ms' if row.get('frames') else 'FAILED (see the report)'))

    def run(self):
        p = self.plan
        runs = schedule(p)
        self.log(f'plan {p["name"]}: variants {[v["name"] for v in p["variants"]]}, scenes {p["scenes"]}, '
                 f'{len(runs)} variant runs, order {p["order"]} -> {self.out}')
        for i, (v, r) in enumerate(runs):
            self.log(f'  {i + 1:2d}. {v["name"]} round {r}: ' + v['text'].replace('\n', ' ')
                     + (' | live ' + ' '.join(v['live']) if v['live'] else ''))
        if self.dry:
            return
        self.live = Live()
        self.log(f'live log {self.live.path} (idle {self.live.age():.0f} s)')
        orig = ssh(f'cat {ENV_PATH} 2>/dev/null', check=False)
        open(os.path.join(self.out, 'mtl2-env.orig'), 'w').write(orig)
        ssh('cat > /var/tmp/labtrace.sh', inp=open(os.path.join(TOOLS, 'labtrace.sh'), 'rb').read())
        usage = ssh('/var/local/bin/sweettrace -h 2>&1; true', check=False)
        self.full_trace = '-F PROCS' not in usage
        if self.full_trace:
            self.log('sweettrace without -f/-z (not the ws-u-lab build): full traces, reduced on the PC (slower pulls)')
        seq = 0
        try:
            for v, r in runs:
                self.check_stop()
                temp, batt = self.guard()
                info = {}
                live_mark = None
                if p['uses_live']:       # before a restart too: the new backboardd reads it at its first commit
                    ssh(f'cat > {LIVE_PATH}', inp=v['live_text'].encode())
                    live_mark = self.live.mark()
                if p['restart'] == 'always' or self.cur_env != v['text']:
                    info = self.apply_env(v)
                for s in p['scenes']:
                    self.check_stop()
                    temp, batt = self.guard()
                    seq += 1
                    tid = f'{seq:02d}-{v["name"]}-{s}-r{r}'
                    d = self.ensure_display()
                    self.unlock_home()
                    nav, mode, app = self.scene(s)
                    local, tinfo = self.trace(tid, mode)
                    if live_mark is not None:
                        ok = re.search(r'MTL2\[\d+ backboardd\]: native-metal: live: [^\n]*', self.live.since(live_mark))
                        tinfo['live_ok'] = int(bool(ok))
                        if not ok:
                            self.log('live: WARNING no "native-metal: live:" line from backboardd (frontend without '
                                     'ws-u-lab live knobs?)')
                        live_mark = None
                    row = dict(seq=seq, id=tid, variant=v['name'], scene=s, round=r, time=time.strftime('%H:%M:%S'),
                               temp_c=temp, battery=batt, display=d, nav=nav, **info, **tinfo)
                    info = {k: info[k] for k in info if k == 'bb_pid'}      # restart numbers only on its first row
                    self.analyze_start(local, tid, app, row)
        except Stop as e:
            self.log(f'STOPPED: {e}')
        finally:
            self.reap(block=True)
            if p['restore'] and self.live is not None and self.cur_env is not None:
                try:
                    if p['uses_live']:
                        ssh(f'cat > {LIVE_PATH}', inp=b'')    # empty: every knob back to its env value
                    self.log('restore: original mtl2-env, backboardd restart')
                    self.apply_env(dict(name='orig', text=orig))
                except Exception as e:      # noqa: BLE001
                    self.log(f'restore FAILED: {e}')
        table = ab_table(self.rows, [v['name'] for v in p['variants']], p['scenes'])
        open(os.path.join(self.out, 'ab.txt'), 'w').write(table)
        print(table)
        self.log(f'done in {(time.time() - self.t0) / 60:.1f} min: {len(self.rows)} traces -> {self.out}/summary.tsv, ab.txt')


# ---------------------------------------------------------------- summary
COLS = ['seq', 'id', 'variant', 'scene', 'round', 'time', 'temp_c', 'battery', 'display', 'nav', 'bb_pid',
        'prewarm_pipes', 'prewarm_ms', 'restart_s', 'env_ok', 'live_ok', 'trace_mb', 'trace_s', 'pull_s', 'pull',
        'frames', 'fps', 'int_p50', 'int_p90', 'int_mean', 'v1', 'v2', 'v3p', 'v1_swipe', 'v2_swipe', 'v3p_swipe',
        'pct1v_swipe', 'gpu_p50', 'gpu_p90', 'gpu_swipe_p50', 'msg_to_bbwake_p50', 'bbwake_to_submit_p50',
        'bbwake_to_submit_p90', 'submit_to_done_p50', 'touch_to_appwake_p50', 'disp_oncpu_ms', 'app_oncpu_ms',
        'cause_gpu', 'cause_bbcpu', 'cause_app']
# A/B table: (column, label, better) better = -1 lower is better, +1 higher
AB = [('fps', 'frames/s on screen', 1), ('int_p50', 'interval p50 ms', -1), ('int_p90', 'interval p90 ms', -1),
      ('int_mean', 'interval mean ms', -1), ('pct1v_swipe', '% 1-vsync (swipes)', 1), ('v3p_swipe', '3+ vsync (swipes)', -1),
      ('gpu_p50', 'GPU p50 ms', -1), ('gpu_p90', 'GPU p90 ms', -1), ('msg_to_bbwake_p50', 'app msg->bb wake p50', -1),
      ('bbwake_to_submit_p50', 'bb wake->submit p50', -1), ('bbwake_to_submit_p90', 'bb wake->submit p90', -1),
      ('disp_oncpu_ms', 'display thr on-CPU ms', -1), ('prewarm_ms', 'prewarm ms', -1)]


def metrics(js):
    try:
        d = json.load(open(js))
    except (OSError, ValueError):
        return {}

    def g(*path):
        o = d
        for k in path:
            if not isinstance(o, dict) or k not in o:
                return ''
            o = o[k]
        return o
    iv = d.get('interval_vsyncs') or {}
    ivs = d.get('interval_vsyncs_swipe') or {}
    n_sw = sum(v for v in ivs.values() if isinstance(v, (int, float)))
    rc = d.get('root_cause_groups') or {}
    span = d.get('span_ms') or 0
    return dict(
        frames=d.get('frames', ''), fps=round(d['frames'] * 1000 / span, 1) if span and d.get('frames') else '',
        int_p50=g('interval_ms', 'median'), int_p90=g('interval_ms', 'p90'), int_mean=g('interval_ms', 'mean'),
        v1=iv.get('1', ''), v2=iv.get('2', ''), v3p=(iv.get('3', 0) or 0) + (iv.get('4+', 0) or 0),
        v1_swipe=ivs.get('1', ''), v2_swipe=ivs.get('2', ''), v3p_swipe=(ivs.get('3', 0) or 0) + (ivs.get('4+', 0) or 0),
        pct1v_swipe=round(100 * ivs.get('1', 0) / n_sw, 1) if n_sw else '',
        gpu_p50=g('gpu_ms', 'median'), gpu_p90=g('gpu_ms', 'p90'), gpu_swipe_p50=g('gpu_ms_swipe', 'median'),
        msg_to_bbwake_p50=g('stage_gaps_ms', 'app->bb msg -> bb wake', 'median'),
        bbwake_to_submit_p50=g('stage_gaps_ms', 'bb wake -> GPU submit', 'median'),
        bbwake_to_submit_p90=g('stage_gaps_ms', 'bb wake -> GPU submit', 'p90'),
        submit_to_done_p50=g('stage_gaps_ms', 'GPU submit -> GPU done', 'median'),
        touch_to_appwake_p50=g('stage_gaps_ms', 'touch -> app wake', 'median'),
        disp_oncpu_ms=d.get('display_thread_oncpu_ms', ''), app_oncpu_ms=d.get('app_main_oncpu_ms', ''),
        cause_gpu=(rc.get('GPU') or {}).get('all', ''),
        cause_bbcpu=(rc.get('encode too long (bb CPU)') or {}).get('all', ''),
        cause_app=(rc.get('no new commit (app cadence)') or {}).get('all', ''))


def write_tsv(out, rows):
    rows = sorted(rows, key=lambda r: r['seq'])
    with open(os.path.join(out, 'summary.tsv'), 'w') as f:
        f.write('\t'.join(COLS) + '\n')
        for r in rows:
            f.write('\t'.join(str(r.get(c, '')) for c in COLS) + '\n')


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def ab_table(rows, variants, scenes):
    out = []
    ref = variants[0]
    for s in scenes:
        rs = [r for r in rows if r['scene'] == s]
        if not rs:
            continue
        ns = {v: len([r for r in rs if r['variant'] == v and r.get('frames')]) for v in variants}
        hdr = f'{"scene " + s:<26}' + ''.join(f'{v + " (n=" + str(ns[v]) + ")":>16}' for v in variants)
        hdr += ''.join(f'{"d " + v + "-" + ref:>18}' for v in variants[1:])
        out.append(hdr)
        out.append('-' * len(hdr))
        for col, label, better in AB:
            med = {}
            for v in variants:
                vals = [num(r.get(col)) for r in rs if r['variant'] == v]
                vals = [x for x in vals if x is not None]
                med[v] = statistics.median(vals) if vals else None
            if all(m is None for m in med.values()):
                continue
            line = f'{label:<26}' + ''.join(f'{med[v]:>16.2f}' if med[v] is not None else f'{"-":>16}' for v in variants)
            for v in variants[1:]:
                if med[v] is None or med[ref] is None:
                    line += f'{"-":>18}'
                    continue
                dlt = med[v] - med[ref]
                pct = f' ({100 * dlt / med[ref]:+.0f}%)' if med[ref] else ''
                mark = '' if dlt == 0 else ('+' if dlt * better > 0 else '-')
                line += f'{dlt:>+10.2f}{pct:>7}{mark}'
            out.append(line)
        # spread: per variant min..max of the interval p50 and GPU p50 (is the difference bigger than the noise?)
        for col in ('int_p50', 'gpu_p50', 'pct1v_swipe'):
            parts = []
            for v in variants:
                vals = sorted(x for x in (num(r.get(col)) for r in rs if r['variant'] == v) if x is not None)
                parts.append(f'{v} {vals[0]:.1f}..{vals[-1]:.1f}' if vals else f'{v} -')
            out.append(f'  range {col}: ' + ', '.join(parts))
        out.append('')
    out.append('medians over rounds; d = variant - ' + ref + ' (+ better / - worse); full rows in summary.tsv')
    return '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('plan', nargs='?')
    ap.add_argument('--dry-run', action='store_true', help='print the schedule and the env files; no phone')
    ap.add_argument('--out', help='output directory (default logs/exp-NAME-MMDD-HHMM)')
    ap.add_argument('--analyze-only', metavar='DIR', help='rebuild summary.tsv and ab.txt from DIR/*.json')
    a = ap.parse_args()
    if a.analyze_only:
        rows = []
        variants, scenes = [], []
        for f in sorted(os.listdir(a.analyze_only)):
            m = re.match(r'^(\d+)-(.+)-(settings|pages|scroll|idle)-r(\d+)\.json$', f)
            if not m:
                continue
            row = dict(seq=int(m.group(1)), id=f[:-5], variant=m.group(2), scene=m.group(3), round=int(m.group(4)))
            row.update(metrics(os.path.join(a.analyze_only, f)))
            rows.append(row)
            variants += [row['variant']] if row['variant'] not in variants else []
            scenes += [row['scene']] if row['scene'] not in scenes else []
        if a.plan:
            variants = [v['name'] for v in parse_plan(a.plan)['variants']]
        write_tsv(a.analyze_only, rows)
        t = ab_table(rows, variants, scenes)
        open(os.path.join(a.analyze_only, 'ab.txt'), 'w').write(t)
        print(t)
        return
    if not a.plan:
        ap.error('PLAN needed')
    plan = parse_plan(a.plan)
    out = a.out or os.path.join(P, 'logs', f'exp-{plan["name"]}-{time.strftime("%m%d-%H%M")}')
    if not a.dry_run:
        os.makedirs(out, exist_ok=True)
        shutil.copy(a.plan, os.path.join(out, 'plan.txt'))
        open(os.path.join(out, 'pid'), 'w').write(str(os.getpid()))
    Runner(plan, out, a.dry_run).run()


if __name__ == '__main__':
    main()
