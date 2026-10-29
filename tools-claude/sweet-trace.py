#!/usr/bin/env python3
"""
sweet-trace.py: read a sweettrace file (phone/tools/sweettrace.c, kdebug: sched, IPC, interrupts and 0994's
display/GPU/touch events) and show who wakes whom in the frame chain.

  sweet-trace.py TRACE.swtr [--json OUT.json] [--all] [--app Preferences] [--frames N] [--from MS] [--to MS]

  --json OUT   Chrome/Perfetto trace (ui.perfetto.dev, chrome://tracing): one track per thread (running, blocked with
               the waker in the slice name and a flow arrow from it, runnable), a "calls" track per thread (IOMFB and
               accelerator methods, swap, present, GPU submit/wait), and tracks for vsync, notifications, GPU busy
               (fence stamps), scanout flip/latch/on screen and touch.
  --all        every thread in the JSON (default: backboardd, the app, SpringBoard, and the threads that wake them)
  --app NAME   the app process (default Preferences, the Settings app)
  --frames N   per-frame lines to print (default 40; the summary uses all)
  --from/--to  window in ms from the trace start
  --dump       print every 0994 event as text (for checking the kernel side)
  --pace       frame pacing: panel edges from the INTF frame counter, each frame's edge, and for every frame that
               took 2 vsyncs or more the stage that was running when the edge it missed went by (cause table),
               plus the app tick / commit / backboardd tick phase against the panel edges over time
  --pace-frames N  also print the first N late frames with their chain (ms relative to the missed edge)
  --pace-swipes    only those during swipes (touch .. 700 ms after it)

Prints a per-frame critical path for each frame that went on screen (direct scanout latch, or a present):
touch -> app main thread wake (and its waker) -> app message to backboardd -> backboardd display thread wake (and
its waker) -> first GPU submit -> GPU done (fence end stamp) -> SwapEnd -> flip -> latch -> next vsync tick,
with the gaps in ms; then the typical gaps, which one dominates, and the vsync tick / notification accounting.
"""
import argparse
import bisect
import collections
import json
import math
import struct
import sys

HDR = struct.Struct('<8sIIIIQQQIIIIIIiIQ128s')
KD = struct.Struct('<QQQQQQIIQ')
THR = struct.Struct('<QiI32s64s')

# kdebug ids
def code(cls, sub, c):
    return (cls << 24) | (sub << 16) | (c << 2)

MACH_SCHED = code(1, 0x40, 0x00)
MACH_STACK_HANDOFF = code(1, 0x40, 0x02)
MACH_MAKERUNNABLE = code(1, 0x40, 0x06)
MACH_IDLE = code(1, 0x40, 0x09)
MACH_BLOCK = code(1, 0x40, 0x0f)
MACH_WAIT = code(1, 0x40, 0x10)
INTR = code(1, 0x05, 0)
IPC_SEND = code(1, 0x20, 0x03)
IPC_RECV = code(1, 0x20, 0x04)
IPC_RECV_NV = code(1, 0x20, 0x05)
IPC_KMSG_INFO = code(1, 0x20, 0x0a)
TRACE_NEWTHREAD = code(7, 0, 1)
TRACE_THREADNAME = code(7, 1, 4)
TRACE_STRING_GLOBAL = code(7, 1, 0)
TRACE_EXEC = code(7, 1, 2)

SW = {0x01: 'VSYNC', 0x02: 'VSYNC_SEND', 0x03: 'NOTIFY', 0x04: 'IOMFB_SEL', 0x05: 'SWAP', 0x06: 'PRESENT',
      0x07: 'SHOWN', 0x08: 'SWAPDONE', 0x09: 'SCAN_SWAP', 0x0a: 'SCAN_FLIP', 0x0b: 'SCAN_LATCH', 0x0c: 'SCAN_BP',
      0x10: 'GPU_SUBMIT', 0x11: 'GPU_DONE', 0x12: 'GPU_WAIT', 0x13: 'GPU_CAL', 0x14: 'GPU_GATE', 0x15: 'ACCEL_SEL',
      0x20: 'TOUCH'}
SW_BASE = (6 << 24) | (0xF5 << 16)
IOMFB_SEL_NAMES = {3: 'GetLayerDefaultSurface', 4: 'SwapBegin', 5: 'SwapEnd', 6: 'SwapWait', 7: 'GetID',
                   8: 'GetDisplaySize', 12: 'RequestPowerChange', 18: 'IsMainDisplay', 28: 'GetDotPitch',
                   72: 'Notifications', 77: 'GetCurrentAbsoluteTime', 79: 'GetBlock'}
ACCEL_NAMES = {1: 'Query', 2: 'BoAlloc', 3: 'BoMap', 4: 'BoFree', 5: 'Submit', 6: 'WaitFence', 7: 'GetTimestamp',
               8: 'GetStatus', 9: 'SetMetadata', 10: 'GetMetadata', 11: 'CreateQueue', 12: 'CloseQueue',
               13: 'BoCpuMap', 14: 'BoCpuUnmap', 15: 'GetDeviceInfo', 16: 'BoImport'}
CALL_CODES = {0x04, 0x05, 0x06, 0x0c, 0x10, 0x12, 0x14, 0x15}   # START/END pairs drawn on a thread's calls track


def cstr(b):
    return b.split(b'\0', 1)[0].decode('utf-8', 'replace')


class Trace:
    def __init__(self, path):
        data = open(path, 'rb').read()
        h = HDR.unpack_from(data, 0)
        if h[0] != b'SWTRACE1':
            sys.exit(f'{path}: not a sweettrace file')
        (_, self.version, hsize, self.numer, self.denom, self.start_abs, self.end_abs, n_events, n_threads,
         self.ncpu, self.kd_flags, self.kbufs, self.reads, self.dropped, self.tracer_pid, self.read_ms,
         self.wall_ns, args) = h
        self.args = cstr(args)
        off = hsize
        self.events = list(KD.iter_unpack(data[off:off + n_events * KD.size]))
        off += n_events * KD.size
        self.threads = {}
        for tid, pid, flags, comm, name in THR.iter_unpack(data[off:off + n_threads * THR.size]):
            self.threads[tid] = [pid, cstr(comm), cstr(name)]
        self.events.sort(key=lambda e: e[0])

    def ms(self, abs_t):
        return (abs_t - self.start_abs) * self.numer / self.denom / 1e6

    def abs_of_ns(self, ns):
        return ns * self.denom / self.numer


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('trace')
    ap.add_argument('--json')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--app', default='Preferences')
    ap.add_argument('--frames', type=int, default=40)
    ap.add_argument('--from', dest='t_from', type=float, default=None)
    ap.add_argument('--to', dest='t_to', type=float, default=None)
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--pace', action='store_true')
    ap.add_argument('--pace-frames', type=int, default=0)
    ap.add_argument('--pace-swipes', action='store_true')
    a = ap.parse_args()

    T = Trace(a.trace)
    ms = T.ms
    span = ms(T.end_abs)
    print(f'{a.trace}: {len(T.events)} events, {span:.0f} ms, {len(T.threads)} threads, {T.ncpu} CPUs, '
          f'kernel buffer {T.kbufs}, {T.reads} reads; args "{T.args}"')
    if T.kd_flags & 0x8:
        print('WARNING: the kernel buffer wrapped: events were lost (bigger -b, or a shorter -r)')
    if T.dropped:
        print(f'WARNING: {T.dropped} events dropped by sweettrace (-m)')

    threads = T.threads        # tid -> [pid, comm, name]
    names_pending = {}

    def tname(tid):
        t = threads.get(tid)
        if t is None:
            return f'tid {tid}'
        nm = t[2]
        return f'{t[1]}[{t[0]}]/{nm or tid}'

    def tpid(tid):
        t = threads.get(tid)
        return t[0] if t else -1

    def tproc(tid):
        t = threads.get(tid)
        return t[1] if t else '?'

    # ---- pass 1: scheduling, wakes, IPC, our events ----
    cpu_cur = {}               # cpu -> tid running
    cpu_intr = collections.defaultdict(int)
    run_start = {}             # tid -> abs when it went on CPU
    off_start = {}             # tid -> abs when it went off CPU
    pend_wake = {}             # tid -> (abs, waker tid, irq?)
    slices = collections.defaultdict(list)     # tid -> (start, end, kind, info)
    wakes = collections.defaultdict(list)      # tid -> (wake abs, oncpu abs, waker tid, in irq)
    oncpu_abs = collections.defaultdict(int)
    msgs = []                  # (abs, sender tid, send pid, dst pid, size)
    sw = collections.defaultdict(list)         # name -> [(abs, tid, func, a1, a2, a3, a4)]
    call_stack = collections.defaultdict(list) # tid -> [(code, abs, a1..a4)]
    calls = collections.defaultdict(list)      # tid -> (start, end, name, args)
    t_lo = T.start_abs + (T.abs_of_ns(a.t_from * 1e6) if a.t_from is not None else 0)
    t_hi = T.start_abs + (T.abs_of_ns(a.t_to * 1e6) if a.t_to is not None else float('inf'))

    def go_off(tid, t):
        s = run_start.pop(tid, None)
        if s is not None:
            slices[tid].append((s, t, 'running', None))
            oncpu_abs[tid] += t - s
        off_start[tid] = t

    def go_on(tid, t):
        s = off_start.pop(tid, None)
        w = pend_wake.pop(tid, None)
        if s is not None:
            if w is not None and w[0] >= s:
                slices[tid].append((s, w[0], 'blocked', w))
                slices[tid].append((w[0], t, 'runnable', w))
                wakes[tid].append((w[0], t, w[1], w[2]))
            else:
                slices[tid].append((s, t, 'preempted', None))
        elif w is not None:
            wakes[tid].append((w[0], t, w[1], w[2]))
        run_start[tid] = t

    for e in T.events:
        ts, a1, a2, a3, a4, tid, dbg, cpu, _ = e
        if ts < t_lo or ts > t_hi:
            continue
        cid = dbg & ~3
        fn = dbg & 3
        if cid == MACH_SCHED or cid == MACH_STACK_HANDOFF:
            new = a2
            old = cpu_cur.get(cpu, tid)
            if old != new:
                go_off(old, ts)
                go_on(new, ts)
            cpu_cur[cpu] = new
        elif cid == MACH_MAKERUNNABLE:
            pend_wake[a1] = (ts, tid, cpu_intr[cpu] > 0)        # arg5: the waker (the interrupted thread in an IRQ)
        elif cid == INTR:
            if fn == 1:
                cpu_intr[cpu] += 1
            elif fn == 2 and cpu_intr[cpu] > 0:
                cpu_intr[cpu] -= 1
        elif cid == IPC_KMSG_INFO and fn == 2:
            msgs.append((ts, tid, a1, a2, a3))
        elif cid == TRACE_NEWTHREAD:
            threads.setdefault(a1, [a2, threads.get(tid, [0, '?', ''])[1], ''])
        elif cid == TRACE_STRING_GLOBAL:
            # kernel_debug_string: START a1 = the string's debugid, a2 = id, a3-a4 = 16 chars; then 32 chars per event
            if fn & 1:
                names_pending[tid] = struct.pack('<QQ', a3, a4) if (a1 & ~3) == TRACE_THREADNAME else None
            elif names_pending.get(tid) is not None:
                names_pending[tid] += struct.pack('<QQQQ', a1, a2, a3, a4)
            if fn & 2 and names_pending.get(tid) is not None:
                nm = cstr(names_pending.pop(tid))
                if nm:
                    threads.setdefault(tid, [-1, '?', ''])[2] = nm
        elif (dbg & 0xffff0000) == SW_BASE:
            c = (dbg >> 2) & 0x3fff
            name = SW.get(c, f'0x{c:x}')
            if c in CALL_CODES and fn in (1, 2):
                if fn == 1:
                    call_stack[tid].append((c, ts, a1, a2, a3, a4))
                else:
                    st = call_stack[tid]
                    for i in range(len(st) - 1, -1, -1):
                        if st[i][0] == c:
                            s = st.pop(i)
                            calls[tid].append((s[1], ts, c, s[2:], (a1, a2, a3, a4)))
                            break
            sw[name].append((ts, tid, fn, a1, a2, a3, a4))
            if a.dump:
                f = {0: '', 1: ' START', 2: ' END'}.get(fn, '')
                print(f'{ms(ts):10.3f} cpu{cpu} {tname(tid):40s} {name}{f} {a1:#x} {a2:#x} {a3:#x} {a4:#x}')
    for tid in list(run_start):
        go_off(tid, min(T.end_abs, t_hi))

    # ---- GPU clock -> mach time ----
    cal = [(e[3], (e[4] + e[5]) / 2) for e in sw['GPU_CAL'] if e[3]]
    ticks_per_abs = None
    if len(cal) >= 2 and cal[-1][0] != cal[0][0]:
        ticks_per_abs = (cal[-1][0] - cal[0][0]) / (cal[-1][1] - cal[0][1])
    elif cal:
        ticks_per_abs = 19.2e6 / (1e9 * T.denom / T.numer)
    def gpu_abs(ticks):
        if not cal or not ticks:
            return None
        g0, t0 = cal[0]
        return t0 + (ticks - g0) / ticks_per_abs
    if cal:
        resid = [abs(gpu_abs(g) - t) for g, t in cal]
        mhz = ticks_per_abs * 1e9 * T.denom / T.numer / 1e6
        print(f'GPU clock: {len(cal)} calibration points, {mhz:.4f} MHz against mach time, '
              f'max residual {max(resid) * T.numer / T.denom / 1e3:.1f} us')
    else:
        print('GPU clock: no calibration events (no GPU submits, or no 0994 kernel): GPU stamps not placed')

    # GPU fences: fence -> (start abs, end abs, pid), with RB_DONE_TS the start is max(own, previous end)
    fences = {}
    prev_end = None
    for e in sorted(sw['GPU_DONE'], key=lambda e: e[3]):
        f, s, en, pid = e[3], e[4], e[5], e[6]
        if prev_end and prev_end > s and prev_end < en:
            s = prev_end
        prev_end = en
        sa, ea = gpu_abs(s), gpu_abs(en)
        if sa is not None and ea is not None and ea >= sa:
            fences[f] = (sa, ea, pid)
    submits = []    # (abs end of submit call, tid, fence, pid)
    for e in sw['GPU_SUBMIT']:
        if e[2] == 2 and e[3]:
            submits.append((e[0], e[1], e[3], e[5]))
    submits.sort()

    # ---- processes ----
    def pids_named(n):
        return {v[0] for v in threads.values() if v[1] == n}
    bb = pids_named('backboardd')
    app = pids_named(a.app)
    sb = pids_named('SpringBoard')
    if not bb:
        print('no backboardd in the thread map')
    swapends = [(c[0], tid, c[4][3]) for tid, cl in calls.items() for c in cl if c[2] == 0x04 and c[3][0] == 5]
    swapends.sort()
    disp_threads = collections.Counter(t for _, t, _ in swapends)
    disp = disp_threads.most_common(1)[0][0] if disp_threads else None
    if disp:
        print(f'display thread (SwapEnd caller): {tname(disp)}; {len(swapends)} SwapEnds')
    else:
        # no 0994 events (an older kernel): CA's display thread by name, else backboardd's busiest thread
        cand = [(('coreanimation.display' in v[2]), oncpu_abs[t], t) for t, v in threads.items() if v[0] in bb]
        if cand:
            disp = max(cand)[2]
            print(f'no SwapEnd events (kernel without 0994?): display thread taken as {tname(disp)}')
    # the app's main thread: its busiest thread (the main thread does the scrolling work)
    app_main = None
    if app:
        cand = [(oncpu_abs[t], t) for t, v in threads.items() if v[0] in app]
        if cand:
            app_main = max(cand)[1]
            print(f'app main thread (busiest in {a.app}): {tname(app_main)}')
    else:
        print(f'no {a.app} process in the thread map (--app)')

    def wdesc(w):
        wt, irq = w[2], w[3]
        if irq:
            return f'IRQ on {tname(wt)}'
        return tname(wt)

    def last_wake(tid, before, after=None):
        ws = wakes.get(tid, [])
        i = bisect.bisect_right(ws, (before, float('inf'))) - 1
        while i >= 0:
            if after is None or ws[i][0] >= after:
                return ws[i]
            return None
        return None

    call_iv = {}        # tid -> the union of its kernel-call intervals (sorted, disjoint)
    for t, cl in calls.items():
        u = []
        for s, e in sorted((c[0], c[1]) for c in cl):
            if u and s <= u[-1][1]:
                u[-1] = (u[-1][0], max(u[-1][1], e))
            else:
                u.append((s, e))
        call_iv[t] = u

    def in_call(tid, t):
        iv = call_iv.get(tid, [])
        i = bisect.bisect_right(iv, (t, float('inf'))) - 1
        return i >= 0 and iv[i][0] <= t <= iv[i][1]

    def frame_wake(tid, lo, hi):
        ws = wakes.get(tid, [])
        i = bisect.bisect_left(ws, (lo,))
        first = None
        while i < len(ws) and ws[i][0] <= hi:
            if not in_call(tid, ws[i][0]):
                return ws[i]
            first = first or ws[i]
            i += 1
        return first or last_wake(tid, hi, hi - T.abs_of_ns(100e6))

    # ---- frames: what went on screen ----
    latches = [(e[0], e[3], e[4], e[5]) for e in sw['SCAN_LATCH']]
    flips = {e[3]: e[0] for e in sw['SCAN_FLIP']}
    shown = []      # (abs on screen, swap id, how)
    for ts, swap, seq, lat in latches:
        shown.append((ts, swap, 'latch'))
    if not shown:
        for c in (x for cl in calls.values() for x in cl if x[2] == 0x06 and not x[4][1]):
            shown.append((c[1], c[3][0], 'present'))
    shown.sort()
    vsyncs = sorted(e[0] for e in sw['VSYNC'])
    vsend = sorted(e[0] for e in sw['VSYNC_SEND'])
    touches = sorted(e[0] for e in sw['TOUCH'])
    se_by_swap = {}
    for ts, tid, swap in swapends:
        se_by_swap.setdefault(swap, (ts, tid))
    bb_msgs = sorted((m[0], m[1]) for m in msgs if m[2] in app and m[3] in bb)
    period_ms = 16.667
    if len(vsyncs) > 10:
        d = sorted(vsyncs[i + 1] - vsyncs[i] for i in range(len(vsyncs) - 1))
        period_ms = ms(T.start_abs + d[len(d) // 2])

    STAGES = ['touch', 'app wake', 'app->bb msg', 'bb wake', 'GPU submit', 'GPU done', 'SwapEnd', 'flip', 'on screen',
              'next vsync']
    rows = []
    prev_se = None
    for ts, swap, how in shown:
        se = se_by_swap.get(swap)
        if se is None:
            continue
        se_t, se_tid = se
        st = dict.fromkeys(STAGES)
        info = {}
        st['SwapEnd'] = se_t
        st['on screen'] = ts
        st['flip'] = flips.get(swap)
        i = bisect.bisect_right(vsyncs, ts)
        st['next vsync'] = vsyncs[i] if i < len(vsyncs) else None
        # the frame's GPU work: the swapper's submits since its previous SwapEnd
        lo = prev_se if prev_se is not None and prev_se < se_t else se_t - T.abs_of_ns(100e6)
        sub = [s for s in submits if lo < s[0] <= se_t and s[1] == se_tid] or \
              [s for s in submits if lo < s[0] <= se_t and s[3] in bb]
        prev_se = se_t
        if sub:
            st['GPU submit'] = sub[0][0]
            fe = fences.get(sub[-1][2])
            if fe:
                st['GPU done'] = fe[1]
            info['gpu ms'] = sum(ms(T.start_abs + fences[s[2]][1] - fences[s[2]][0]) for s in sub if s[2] in fences)
        # the display thread's wake that started this frame: its first wake since the previous SwapEnd that is not
        # inside one of its kernel calls (SwapWait, fence waits), before its first submit (or this SwapEnd)
        ref = st['GPU submit'] or se_t
        w = frame_wake(se_tid, lo, ref)
        if w:
            st['bb wake'] = w[0]
            info['bb waker'] = wdesc(w)
            # the app's message to backboardd before that wake
            j = bisect.bisect_right(bb_msgs, (w[0], float('inf'))) - 1
            if j >= 0 and w[0] - bb_msgs[j][0] < T.abs_of_ns(50e6):
                st['app->bb msg'] = bb_msgs[j][0]
                if app_main:
                    aw = last_wake(app_main, bb_msgs[j][0], bb_msgs[j][0] - T.abs_of_ns(100e6))
                    if aw:
                        st['app wake'] = aw[0]
                        info['app waker'] = wdesc(aw)
                        k = bisect.bisect_right(touches, aw[0]) - 1
                        if k >= 0 and aw[0] - touches[k] < T.abs_of_ns(100e6):
                            st['touch'] = touches[k]
        rows.append((swap, how, st, info))

    def gap(st, x, y):
        if st[x] is None or st[y] is None:
            return None
        return ms(T.start_abs + st[y] - st[x]) if st[y] >= st[x] else -ms(T.start_abs + st[x] - st[y])

    PAIRS = list(zip(STAGES, STAGES[1:]))
    print()
    print(f'per-frame critical path ({len(rows)} frames on screen; vsync period {period_ms:.2f} ms). '
          'Gaps in ms; "-" = stage not found; negative = out of the listed order')
    hdr = ' '.join(f'{x[:4]}>{y[:4]:>4}' for x, y in PAIRS)
    print(f'{"t ms":>9} {"swap":>6} {"intv":>6} | {hdr} | bb waker / app waker')
    prev_on = None
    intervals = []
    for swap, how, st, info in rows:
        intv = ms(T.start_abs + st['on screen'] - prev_on) if prev_on else None
        prev_on = st['on screen']
        if intv is not None:
            intervals.append(intv)
        if len(intervals) > a.frames and a.frames >= 0:
            continue
        gs = []
        for x, y in PAIRS:
            g = gap(st, x, y)
            gs.append(f'{g:9.2f}' if g is not None else f'{"-":>9}')
        print(f'{ms(st["on screen"]):9.1f} {swap:6d} {intv if intv is not None else 0:6.1f} | {" ".join(gs)} | '
              f'{info.get("bb waker", "-")} / {info.get("app waker", "-")}')

    # ---- summary ----
    def stats(v):
        v = sorted(v)
        if not v:
            return '-'
        return (f'n {len(v):4d} median {v[len(v) // 2]:7.2f} p90 {v[min(len(v) - 1, len(v) * 9 // 10)]:7.2f} '
                f'mean {sum(v) / len(v):7.2f}')
    print()
    print('typical gaps (ms):')
    dom = collections.Counter()
    for x, y in PAIRS:
        v = [gap(st, x, y) for _, _, st, _ in rows]
        v = [g for g in v if g is not None]
        print(f'  {x:>12} -> {y:<12} {stats(v)}')
    for _, _, st, _ in rows:
        gs = [(gap(st, x, y), f'{x} -> {y}') for x, y in PAIRS]
        gs = [g for g in gs if g[0] is not None and g[0] > 0]
        if gs:
            dom[max(gs)[1]] += 1
    if dom:
        print('largest gap per frame:', ', '.join(f'{k} {n}x' for k, n in dom.most_common()))
    if intervals:
        per = collections.Counter(min(4, max(1, round(i / period_ms))) for i in intervals)
        print(f'on-screen intervals: {stats(intervals)}; in vsync periods: ' +
              ', '.join(f'{k}{"+" if k == 4 else ""}: {per[k]}' for k in sorted(per)))
    wk = collections.Counter()
    for _, _, _, info in rows:
        if 'bb waker' in info:
            wk[info['bb waker']] += 1
    if wk:
        print('display thread woken by:', '; '.join(f'{k} {n}x' for k, n in wk.most_common(6)))
    if rows:
        g = [info['gpu ms'] for _, _, _, info in rows if 'gpu ms' in info]
        if g:
            print(f'GPU time per frame (fence stamps): {stats(g)}')

    # vsync accounting
    ticks = sw['VSYNC']
    sent = sum(1 for e in ticks if e[3 + 1])
    print()
    print(f'vsync timer ticks {len(ticks)} (notification sent {sent}, held {len(ticks) - sent}); '
          f'notifications out {len(vsend)} (any reason)')
    notes = sw['NOTIFY']
    drop = [e for e in notes if e[5]]
    if notes:
        print(f'IOMFB notifications {len(notes)}, failed/dropped {len(drop)}' +
              (f' (IOReturn {drop[0][5]:#x})' if drop else ''))
    if disp and vsend:
        dw = [w for w in wakes.get(disp, [])]
        wt = [w[0] for w in dw]
        led, woke, lat = 0, 0, []
        se_t = [s[0] for s in swapends]
        for i, v in enumerate(vsend):
            nxt = vsend[i + 1] if i + 1 < len(vsend) else T.end_abs
            j = bisect.bisect_left(wt, v)
            if j < len(wt) and wt[j] < nxt:
                woke += 1
                lat.append(ms(T.start_abs + wt[j] - v))
            k = bisect.bisect_left(se_t, v)
            if k < len(se_t) and se_t[k] < nxt:
                led += 1
        print(f'after a vsync notification, before the next: display thread woke {woke}/{len(vsend)} '
              f'(latency {stats(lat)}), a SwapEnd followed {led}/{len(vsend)}')
    def wake_iv(tid):
        w = [x[0] for x in wakes.get(tid, [])]
        return stats([ms(T.start_abs + w[i + 1] - w[i]) for i in range(len(w) - 1)])
    if disp:
        print(f'display thread wake-to-wake interval: {wake_iv(disp)}')
    if app_main:
        print(f'app main thread wake-to-wake interval: {wake_iv(app_main)}')
    if app_main:
        aw = wakes.get(app_main, [])
        c = collections.Counter(wdesc(w) for w in aw)
        print(f'app main thread: {len(aw)} wakes, on CPU {ms(T.start_abs + oncpu_abs[app_main]):.0f} ms; woken by: ' +
              '; '.join(f'{k} {n}x' for k, n in c.most_common(5)))
    if disp:
        c = collections.Counter(wdesc(w) for w in wakes.get(disp, []))
        print(f'display thread: {len(wakes.get(disp, []))} wakes, on CPU {ms(T.start_abs + oncpu_abs[disp]):.0f} ms; '
              'woken by: ' + '; '.join(f'{k} {n}x' for k, n in c.most_common(5)))
    if msgs:
        pairs = collections.Counter((m[2], m[3]) for m in msgs if (m[2] in app | bb | sb) or (m[3] in app | bb | sb))
        def pn(p):
            for v in threads.values():
                if v[0] == p:
                    return f'{v[1]}[{p}]'
            return f'pid {p}'
        print('mach messages (sender -> receiver, count over the trace): ' +
              '; '.join(f'{pn(s)}->{pn(d)} {n}' for (s, d), n in pairs.most_common(8)))
    for nm in ('SCAN_SWAP', 'SCAN_BP', 'GPU_GATE', 'SWAPDONE'):
        if sw[nm]:
            print(f'{nm}: {len(sw[nm])} events')

    if a.pace:
        pace_report(a, T, threads, sw, calls, wakes, slices, msgs, fences, disp, app_main, bb, app, gpu_abs)

    if a.json:
        write_json(a, T, threads, slices, calls, sw, fences, bb, app, sb, wakes, tname, gpu_abs)


def pace_report(a, T, threads, sw, calls, wakes, slices, msgs, fences, disp, app_main, bb, app, gpu_abs):
    """--pace: which stage was running when the panel edge a late frame needed went by."""
    MS = T.abs_of_ns(1e6)            # 1 ms in absolute time units
    ms = lambda d: d / MS            # a duration in ms
    at = lambda t: T.ms(t)           # a time in ms from the trace start
    print()
    print('pacing (--pace)')
    if disp is None:
        print('  no display thread: nothing to do')
        return
    # ---- panel edges: VSYNC a4 = INTF1 frame counter when the tick ran (counts at each panel frame start) ----
    ticks = sorted((e[0], e[6], e[4]) for e in sw['VSYNC'] if e[6])          # (abs, frame counter, sent)
    if len(ticks) < 20:
        print('  fewer than 20 vsync ticks with an INTF frame count: no edge model')
        return
    n = len(ticks)
    mf = sum(f for _, f, _ in ticks) / n
    mt = sum(t for t, _, _ in ticks) / n
    P = sum((f - mf) * (t - mt) for t, f, _ in ticks) / sum((f - mf) ** 2 for _, f, _ in ticks)
    res = [t - f * P for t, f, _ in ticks]
    W = 40      # a calibration tick (polls the counter, so it runs right at an edge) every 32 ticks
    from collections import deque
    off = [0.0] * n
    dq = deque()
    # sliding-window minimum of the residuals: tick time - f * P >= edge offset, equal at a calibration tick
    j = 0
    for i in range(n):
        while j < n and j <= i + W:
            while dq and res[dq[-1]] >= res[j]:
                dq.pop()
            dq.append(j)
            j += 1
        while dq[0] < i - W:
            dq.popleft()
        off[i] = res[dq[0]]
    tick_t = [t for t, _, _ in ticks]

    def edge(f, hint):
        i = min(n - 1, max(0, bisect.bisect_left(tick_t, hint)))
        return off[i] + f * P

    def frame_at(t):
        """the frame counter value at time t (the last edge at or before t)"""
        i = min(n - 1, max(0, bisect.bisect_left(tick_t, t)))
        return math.floor((t - off[i]) / P)

    Pms = ms(P)
    lag = [ms(t - edge(f, t)) for t, f, _ in ticks]
    s_lag = sorted(lag)
    tick_iv = sorted(ms(tick_t[i + 1] - tick_t[i]) for i in range(n - 1))
    print(f'  panel period {Pms:.4f} ms ({1000 / Pms:.3f} Hz) from {n} ticks over frames {ticks[0][1]}-{ticks[-1][1]}; '
          f'tick after its edge: median {s_lag[n // 2]:.2f} p10 {s_lag[n // 10]:.2f} p90 {s_lag[n * 9 // 10]:.2f} ms; '
          f'tick to tick p10 {tick_iv[len(tick_iv) // 10]:.2f} median {tick_iv[len(tick_iv) // 2]:.2f} '
          f'p90 {tick_iv[len(tick_iv) * 9 // 10]:.2f} ms; notification period sent '
          f'{ms(sw["VSYNC_SEND"][0][6]):.3f} ms' if sw['VSYNC_SEND'] else '')
    opts = collections.Counter(e[5] >> 8 for e in sw['VSYNC'])
    lost = sum(1 for i in range(n - 1) if ticks[i + 1][1] - ticks[i][1] >= 2)
    print(f'  ticks lost (the frame counter moved 2+ between two ticks): {lost} of {ticks[-1][1] - ticks[0][1]} edges; '
          'kernel sweetvsync (0995) on the ticks: ' + ', '.join(f'{k:#x} x{v}' for k, v in opts.most_common()))
    vsend = sorted(e[0] for e in sw['VSYNC_SEND'])

    # ---- the display thread's calls ----
    dc = calls.get(disp, [])
    sbegin = {}         # swap id -> SwapBegin end abs
    send_ = {}          # swap id -> (SwapEnd start, end)
    swapwaits = []      # (start, end, id)
    subs = []           # (start, end, fence)
    gates = []          # (start, end)
    for s, e, c, sa, ea in dc:
        if c == 0x04 and sa[0] == 4:
            sbegin.setdefault(ea[2], e)
        elif c == 0x04 and sa[0] == 5:
            send_.setdefault(ea[3], (s, e))
        elif c == 0x04 and sa[0] == 6:
            swapwaits.append((s, e, sa[1] & 0xffffffff))
        elif c == 0x10:
            subs.append((s, e, ea[0]))
        elif c == 0x14:
            gates.append((s, e))
    subs.sort()
    gates.sort()
    swapwaits.sort()
    swap_fence = {}
    for tid, cl in calls.items():
        for s, e, c, sa, ea in cl:
            if c == 0x05:
                swap_fence.setdefault(sa[0], sa[1])
    flips = {e[3]: (e[0], e[6]) for e in sw['SCAN_FLIP']}       # swap -> (abs, INTF frame at the flip)
    latch = {e[3]: e[0] for e in sw['SCAN_LATCH']}

    # ---- app commits: bursts of app -> backboardd messages ----
    am = sorted((m[0], m[4]) for m in msgs if m[2] in app and m[3] in bb and (app_main is None or m[1] == app_main))
    bursts = []         # (first, last, count, largest): a commit is >= 3 messages or one >= 500 bytes
    for t, sz in am:
        if bursts and t - bursts[-1][1] < 0.5 * MS:
            bursts[-1][1] = t
            bursts[-1][2] += 1
            bursts[-1][3] = max(bursts[-1][3], sz)
        else:
            bursts.append([t, t, 1, sz])
    bursts = [b for b in bursts if b[2] >= 3 or b[3] >= 500]
    b_first = [b[0] for b in bursts]
    aw = wakes.get(app_main, []) if app_main else []
    aw_t = [w[0] for w in aw]

    def wclass(w):
        nm = threads.get(w[2], [0, '?', ''])[2] or ''
        if w[3]:
            return 'irq'
        if 'thread call' in nm:
            return 'timer'
        if 'inProcessAnimation' in nm:
            return 'anim'
        if 'eventfetch' in nm:
            return 'touch'
        return 'other'

    def app_tick_of(t0):
        i = bisect.bisect_right(aw_t, t0) - 1
        if i >= 0 and t0 - aw_t[i] < 30 * MS:
            return aw[i]
        return None

    def in_iv(ivs, t):
        i = bisect.bisect_right(ivs, (t, float('inf'))) - 1
        return i >= 0 and ivs[i][0] <= t <= ivs[i][1]

    dsl = sorted(slices.get(disp, []))

    def disp_state(t):
        i = bisect.bisect_right(dsl, (t, float('inf'))) - 1
        if i >= 0 and dsl[i][0] <= t <= dsl[i][1]:
            return dsl[i][2]
        return 'running'

    # ---- frames in the order they reached the panel ----
    path = 'direct scanout: the INTF frame counter at the flip'
    if not flips:
        # present path (0944 swap queue, blit/CPU copy into the panel buffer): on the panel at the first edge after
        # the swap's present is done (SWAPDONE 1 blit fence / 2 CPU copy after its PRESENT)
        done = sorted(e[0] for e in sw['SWAPDONE'] if e[3] in (1, 2))
        for tid, cl in calls.items():
            for s, e, c, sa, ea in cl:
                if c == 0x06 and not ea[1]:
                    k = bisect.bisect_left(done, e)
                    if k < len(done) and done[k] - e < 50 * MS:
                        t = done[k]
                        if sa[0] not in flips or flips[sa[0]][0] > t:
                            flips[sa[0]] = (t, frame_at(t))
        path = 'present path: the first edge after the present\'s blit fence / copy (approximate)'
    frames = []
    for swap, (ft, ff) in sorted(flips.items(), key=lambda x: x[1][0]):
        if swap not in send_:
            continue
        fr = {'swap': swap, 'F': ft, 'n': ff + 1, 'SE': send_[swap][1], 'B': sbegin.get(swap), 'L': latch.get(swap)}
        b = fr['B'] or send_[swap][0]
        fr['B'] = b
        i = bisect.bisect_right(vsend, b) - 1
        fr['V'] = vsend[i] if i >= 0 else None
        k = bisect.bisect_left(subs, (b,))
        fr['S0'] = fr['S1'] = None
        if k < len(subs) and subs[k][0] <= fr['SE']:
            fr['S0'], fr['S1'] = subs[k][0], subs[k][1]
        fe = fences.get(swap_fence.get(swap))
        fr['G'] = fe[1] if fe else None
        fr['gpu'] = ms(fe[1] - fe[0]) if fe else None
        fr['newsub'] = fr['S0'] is not None
        j = bisect.bisect_right(b_first, b) - 1
        fr['C'] = fr['Cb'] = None
        if j >= 0 and b - bursts[j][1] < 40 * MS:
            fr['Cb'] = j
            fr['C0'], fr['C'] = bursts[j][0], bursts[j][1]
            w = app_tick_of(bursts[j][0])
            fr['A'] = w[0] if w else None
            fr['Aw'] = wclass(w) if w else '-'
        frames.append(fr)
    if not frames:
        print('  no flips or presents with a swap id: nothing to do')
        return
    # one frame per edge: a later swap flipped for the same edge replaced the earlier one on the panel
    byn = {}
    for fr in frames:
        byn[fr['n']] = fr
    frames = [byn[k] for k in sorted(byn)]

    CAUSES = collections.OrderedDict([
        ('content', 'a frame without a new app commit (render-server-only change) after a long gap'),
        ('app_rate', 'the app sent nothing for that edge: its commits came >= 1.5 periods apart (app cadence)'),
        ('app_phase', 'app at display rate, its commit just missed bb\'s tick (< P/2 after): app tick ~ bb tick (phase)'),
        ('app_cpu', 'app at display rate, its commit just missed bb\'s tick: app tick well before it, CPU too long'),
        ('bb_busy', 'backboardd still on the previous frame at the tick (its SwapEnd after the tick)'),
        ('bb_skip', 'commit there before the tick, backboardd idle, but no frame from that tick'),
        ('no_tick', 'no vsync tick in the period before the missed edge (a lost tick)'),
        ('swapwait', 'no free surface: SwapWait (swap-done) still blocked at the edge'),
        ('bb_cpu', 'backboardd CPU (render/encode, tick -> GPU submit) across the edge'),
        ('gate', 'no free surface: GPU submit held at the scanout gate (previous frame not latched) at the edge'),
        ('gpu_long', 'GPU busy across the edge, GPU time >= 0.8 period (GPU-bound)'),
        ('gpu_late', 'GPU done after the edge, GPU time < 0.8 period (late start)'),
        ('bb_post', 'backboardd CPU after the submit (SwapEnd after the edge)'),
        ('flip', 'fence and SwapEnd before the edge, flip after it (flip poll / queue)'),
        ('other', 'not classified'),
    ])
    # gestures: touch reports less than 100 ms apart; a swipe window runs until 700 ms after the last report
    tt = sorted(e[0] for e in sw['TOUCH'])
    swin = []
    for t in tt:
        if swin and t - swin[-1][1] < 100 * MS:
            swin[-1][1] = t
        else:
            swin.append([t, t])
    swin = [(s0, s1 + 700 * MS) for s0, s1 in swin]
    in_sw = lambda t: any(s0 <= t <= s1 for s0, s1 in swin)
    cnt_sw = collections.Counter()
    ivs_sw = collections.Counter()
    gpu_sw = []
    cnt = collections.Counter()
    rate_by = collections.Counter()
    gate_gap = []       # GPU-bound frames: previous fence done -> this frame's GPU start (the 2-surface gate idle)
    by_iv = collections.defaultdict(collections.Counter)
    late = []
    ivs = collections.Counter()
    prev = None
    for fr in frames:
        if prev is None:
            prev = fr
            continue
        dn = fr['n'] - prev['n']
        if dn > 30:              # idle: nothing changed for a while
            prev = fr
            continue
        ivs[min(dn, 4)] += 1
        sw_ = in_sw(fr['F'])
        if sw_:
            ivs_sw[min(dn, 4)] += 1
            if fr['gpu'] is not None and fr['newsub']:
                gpu_sw.append(fr['gpu'])
        if dn >= 2:
            D = edge(prev['n'] + 1, fr['F'])        # the edge this frame missed (the first after the previous one)
            why = 'other'
            new_commit = fr['Cb'] is not None and fr['Cb'] != prev.get('Cb')
            start = max(fr['V'] or fr['B'], prev['SE'])     # when backboardd could start this frame
            if fr['F'] < D:
                why = 'flip'
            elif start >= D or (fr['V'] is not None and fr['V'] >= D):
                vi = bisect.bisect_left(vsend, D) - 1      # the last tick before the missed edge
                Vt = vsend[vi] if vi >= 0 else None
                c_iv = None
                if fr['Cb'] is not None and fr['Cb'] > 0:
                    c_iv = fr['C'] - bursts[fr['Cb'] - 1][1]
                if Vt is None or Vt <= D - P:
                    why = 'no_tick'         # no tick in the period before the edge (0946's calibration lost it)
                elif not new_commit:
                    why = 'content'
                elif prev['SE'] >= Vt and prev['SE'] >= D - 1 * MS:
                    why = 'bb_busy'
                elif fr['C'] is not None and fr['C'] > Vt:
                    if c_iv is not None and c_iv < 1.5 * P and fr['C'] - Vt < 0.5 * P:
                        why = 'app_phase' if fr.get('A') and fr['A'] > Vt - 0.3 * MS else 'app_cpu'
                    else:
                        why = 'app_rate'
                        rate_by[fr.get('Aw', '-')] += 1
                elif prev['SE'] >= Vt:
                    why = 'bb_busy'
                else:
                    why = 'bb_skip'
            else:
                S0, S1, G, SE = fr['S0'], fr['S1'], fr['G'], fr['SE']
                if S0 is not None and S0 >= D:
                    blocked = [w for w in swapwaits if w[0] <= D <= w[1] and w[0] >= start - MS]
                    why = 'swapwait' if blocked else 'bb_cpu'
                elif S1 is not None and S1 >= D:
                    why = 'gate'
                elif G is not None and G >= D:
                    why = 'gpu_long' if fr['gpu'] is not None and fr['gpu'] >= 0.8 * Pms else 'gpu_late'
                    if prev['G'] is not None and S1 is not None:
                        gate_gap.append(ms(S1 - prev['G']))
                elif SE >= D:
                    why = 'bb_post' if S0 is not None else ('swapwait' if [w for w in swapwaits if w[0] <= D <= w[1]] else 'bb_cpu')
                else:
                    why = 'flip'
            cnt[why] += 1
            by_iv[min(dn, 4)][why] += 1
            late.append((fr, prev, D, why, dn))
            if sw_:
                cnt_sw[why] += 1
        prev = fr
    tot = sum(ivs.values())
    print(f'  frames by panel edge ({path}), idle gaps > 30 vsyncs left out: '
          + ', '.join(f'{k}{"+" if k == 4 else ""}v {ivs[k]}' for k in sorted(ivs)) + f' (of {tot})')
    tsw = sum(ivs_sw.values())
    print(f'  during the {len(swin)} swipes (touch .. 700 ms after the finger left): '
          + ', '.join(f'{k}{"+" if k == 4 else ""}v {ivs_sw[k]}' for k in sorted(ivs_sw)) + f' (of {tsw})')
    if gpu_sw:
        gpu_sw.sort()
        print(f'    GPU per swipe frame: median {gpu_sw[len(gpu_sw) // 2]:.2f} p10 {gpu_sw[len(gpu_sw) // 10]:.2f} '
              f'p90 {gpu_sw[len(gpu_sw) * 9 // 10]:.2f} ms; >= 0.8 period {sum(1 for x in gpu_sw if x >= 0.8 * Pms)} '
              f'of {len(gpu_sw)}')
    print('  late frames (2v or more): the stage running when the missed edge went by')
    print(f'    {"cause":10s} {"all":>5} {"2v":>5} {"3v":>5} {"4+v":>5} {"swipe":>5}  meaning')
    for k, txt in CAUSES.items():
        if cnt[k]:
            print(f'    {k:10s} {cnt[k]:5d} {by_iv[2][k]:5d} {by_iv[3][k]:5d} {by_iv[4][k]:5d} {cnt_sw[k]:5d}  {txt}')
    if rate_by:
        print('    app_rate by what woke the app main thread for that commit: ' +
              ', '.join(f'{k} {v}' for k, v in rate_by.most_common()) +
              ' (timer: CADisplayLink, anim: UIKit inProcessAnimationManager, touch: eventfetch)')
    if gate_gap:
        gate_gap.sort()
        print(f'    GPU late: previous frame\'s GPU done -> this frame\'s GPU start (held for the previous latch, 2 '
              f'surfaces): median {gate_gap[len(gate_gap) // 2]:.2f} p90 {gate_gap[len(gate_gap) * 9 // 10]:.2f} ms')
    # the suspected race: the tick before the previous frame's latch (swap-done), so the tick finds no free surface
    lt = sorted(latch.values())
    rel = []
    for v in vsend:
        k = bisect.bisect_left(lt, v - 0.5 * P)
        if k < len(lt) and lt[k] < v + 0.5 * P:
            rel.append(ms(lt[k] - v))
    if rel:
        rel.sort()
        print(f'  latch (swap-done) - nearest tick: median {rel[len(rel) // 2]:+.2f} p10 {rel[len(rel) // 10]:+.2f} p90 '
              f'{rel[len(rel) * 9 // 10]:+.2f} ms; latch after the tick {sum(1 for x in rel if x > 0)} of {len(rel)}')
    ll = sorted(ms(fr['L'] - edge(fr['n'], fr['L'])) for fr in frames if fr.get('L') is not None)
    if ll:
        print(f'  latch seen after its edge: median {ll[len(ll) // 2]:.2f} p10 {ll[len(ll) // 10]:.2f} p90 '
              f'{ll[len(ll) * 9 // 10]:.2f} max {ll[-1]:.2f} ms (the scanout thread polls every 1 ms; the gate opens then)')
    swb = sorted(ms(e - s) for s, e, _ in swapwaits if e - s > 0.05 * MS)
    gw = sorted(ms(e - s) for s, e in gates)
    print(f'  display thread: SwapWait blocked {len(swb)} of {len(swapwaits)} calls'
          + (f' (median {swb[len(swb) // 2]:.2f} max {swb[-1]:.2f} ms)' if swb else '')
          + f'; scanout gate held the submit {len(gw)} times' + (f' (median {gw[len(gw) // 2]:.2f} p90 '
                                                                 f'{gw[len(gw) * 9 // 10]:.2f} ms)' if gw else ''))
    g = sorted(fr['gpu'] for fr in frames if fr['gpu'] is not None and fr['newsub'])
    if g:
        print(f'  GPU per frame (frames with a new submit): median {g[len(g) // 2]:.2f} p90 {g[len(g) * 9 // 10]:.2f} '
              f'ms; >= 0.8 period: {sum(1 for x in g if x >= 0.8 * Pms)} of {len(g)}')
    # chain timings relative to the frame's own edge for on-time frames vs late ones
    if a.pace_frames:
        print(f'  first {a.pace_frames} late frames: times in ms relative to the missed edge (A app tick, C commit end, '
              'V bb tick used, B SwapBegin, S0/S1 submit start/end (gate), G GPU done, SE SwapEnd, F flip)')
        for fr, pv, D, why, dn in [x for x in late if not a.pace_swipes or in_sw(x[0]['F'])][:a.pace_frames]:
            r = lambda x: f'{ms(x - D):7.2f}' if x is not None else f'{"-":>7}'
            print(f'    {at(fr["F"]):9.1f} swap {fr["swap"]:#x} {dn}v {why:9s} prevSE {r(pv["SE"])} A {r(fr.get("A"))} '
                  f'({fr.get("Aw", "-"):5s}) C {r(fr["C"])} V {r(fr["V"])} B {r(fr["B"])} S0 {r(fr["S0"])} '
                  f'S1 {r(fr["S1"])} G {r(fr["G"])} SE {r(fr["SE"])} F {r(fr["F"])} gpu '
                  f'{fr["gpu"] if fr["gpu"] is not None else -1:5.2f}')

    # ---- phases against the panel edges over time ----
    def phase(t):
        f = frame_at(t)
        return ms(t - edge(f, t))
    app_ticks = [w[0] for w in aw if wclass(w) == 'timer']
    commits = [b[1] for b in bursts]
    print(f'  phase after the last panel edge (0..{Pms:.2f} ms), per 500 ms: app timer wakes of the main thread '
          '(CADisplayLink), app commit ends, backboardd ticks')
    print(f'    {"t ms":>7} {"app n":>5} {"app ph":>7} {"commit n":>8} {"commit ph":>9} {"bb tick ph":>10}')
    span = T.end_abs - T.start_abs
    nb = int(ms(span) // 500) + 1

    def circ_med(v):
        if not v:
            return None
        # circular median: rotate so the largest gap is at the wrap
        v = sorted(v)
        gaps = [(v[(i + 1) % len(v)] - v[i]) % Pms for i in range(len(v))]
        k = max(range(len(v)), key=lambda i: gaps[i])
        rot = v[k + 1:] + [x + Pms for x in v[:k + 1]]
        return rot[len(rot) // 2] % Pms
    series = []
    for b in range(nb):
        lo_, hi_ = T.start_abs + b * 500 * MS, T.start_abs + (b + 1) * 500 * MS
        ap_ = [phase(t) for t in app_ticks if lo_ <= t < hi_]
        cp_ = [phase(t) for t in commits if lo_ <= t < hi_]
        vp_ = [phase(t) for t in vsend if lo_ <= t < hi_]
        m1, m2, m3 = circ_med(ap_), circ_med(cp_), circ_med(vp_)
        if m1 is not None:
            series.append((b * 500 + 250, m1))
        f_ = lambda m: f'{m:7.2f}' if m is not None else f'{"-":>7}'
        print(f'    {b * 500:7d} {len(ap_):5d} {f_(m1)} {len(cp_):8d} {f_(m2):>9} {f_(m3):>10}')
    # drift of the app timer against the panel: consecutive app timer wakes ~1 period apart
    d = []
    for i in range(len(app_ticks) - 1):
        iv = ms(app_ticks[i + 1] - app_ticks[i])
        if 0.5 * Pms < iv < 1.5 * Pms:
            d.append(iv)
    if d:
        d.sort()
        dm = d[len(d) // 2]
        slope = (dm - Pms) / Pms * 1000
        print(f'  app timer period median {dm:.4f} ms ({len(d)} intervals) vs panel {Pms:.4f} ms: phase moves '
              f'{slope:+.2f} ms per second, one full period every {abs(Pms / slope) if slope else float("inf"):.1f} s')


def write_json(a, T, threads, slices, calls, sw, fences, bb, app, sb, wakes, tname, gpu_abs):
    us = lambda t: (t - T.start_abs) * T.numer / T.denom / 1e3
    focus = {t for t, v in threads.items() if v[0] in (bb | app | sb)}
    keep = set(slices) if a.all else set(focus)
    if not a.all:
        for t in list(focus):
            for w in wakes.get(t, []):
                keep.add(w[2])
    ev = []
    pids_seen = set()
    for t in keep:
        v = threads.get(t, [-1, '?', ''])
        pid = v[0] if v[0] >= 0 else 99999
        if pid not in pids_seen:
            pids_seen.add(pid)
            ev.append({'ph': 'M', 'name': 'process_name', 'pid': pid, 'args': {'name': f'{v[1]} [{pid}]'}})
        ev.append({'ph': 'M', 'name': 'thread_name', 'pid': pid, 'tid': t, 'args': {'name': v[2] or f'{v[1]} {t}'}})
        flow = 0
        for s, e, kind, w in slices.get(t, []):
            if kind == 'running':
                ev.append({'ph': 'X', 'name': 'running', 'pid': pid, 'tid': t, 'ts': us(s), 'dur': us(e) - us(s),
                           'cname': 'good'})
            elif kind == 'blocked':
                nm = f'blocked (woken by {"IRQ on " if w[2] else ""}{tname(w[1])})'
                ev.append({'ph': 'X', 'name': nm, 'pid': pid, 'tid': t, 'ts': us(s), 'dur': us(e) - us(s),
                           'cname': 'grey'})
                if w[1] in keep and t in focus:
                    flow += 1
                    fid = (t << 20) ^ flow
                    wp = threads.get(w[1], [99999])[0]
                    ev.append({'ph': 's', 'id': fid, 'name': 'wake', 'cat': 'wake', 'pid': wp if wp >= 0 else 99999,
                               'tid': w[1], 'ts': us(w[0])})
                    ev.append({'ph': 'f', 'bp': 'e', 'id': fid, 'name': 'wake', 'cat': 'wake', 'pid': pid, 'tid': t,
                               'ts': us(e) + 0.001})
            elif kind == 'runnable':
                ev.append({'ph': 'X', 'name': 'runnable', 'pid': pid, 'tid': t, 'ts': us(s), 'dur': us(e) - us(s),
                           'cname': 'yellow'})
            else:
                ev.append({'ph': 'X', 'name': 'preempted', 'pid': pid, 'tid': t, 'ts': us(s), 'dur': us(e) - us(s),
                           'cname': 'olive'})
    for t, cl in calls.items():
        v = threads.get(t, [-1, '?', ''])
        pid = v[0] if v[0] >= 0 else 99999
        ctid = t + (1 << 40)
        if pid not in pids_seen:
            pids_seen.add(pid)
            ev.append({'ph': 'M', 'name': 'process_name', 'pid': pid, 'args': {'name': f'{v[1]} [{pid}]'}})
        ev.append({'ph': 'M', 'name': 'thread_name', 'pid': pid, 'tid': ctid,
                   'args': {'name': f'{v[2] or t} calls'}})
        for s, e, c, sa, ea in cl:
            if c == 0x04:
                nm = 'IOMFB ' + IOMFB_SEL_NAMES.get(sa[0], f'sel {sa[0]}')
                if sa[0] in (5, 4) and ea[3 if sa[0] == 5 else 2]:
                    nm += f' {ea[3] if sa[0] == 5 else ea[2]}'
                if sa[0] == 6:
                    nm += f' {sa[1] & 0xffffffff}'
            elif c == 0x15:
                nm = 'accel ' + ACCEL_NAMES.get(sa[0], f'method {sa[0]}')
            elif c == 0x10:
                nm = f'GPU submit fence {ea[0]}'
            elif c == 0x12:
                nm = f'GPU wait fence {sa[0]}' + (' TIMEOUT' if ea[1] else '')
            elif c == 0x05:
                nm = f'swap {sa[0]} ({ {0: "pending", 1: "direct", 2: "queue"}.get(ea[1], ea[1]) })'
            elif c == 0x06:
                nm = f'present {sa[0]}' + (' busy' if ea[1] else '')
            elif c == 0x0c:
                nm = f'scanout back pressure (seq {sa[0]})'
            else:
                nm = f'gate wait (seq {sa[1]})'
            ev.append({'ph': 'X', 'name': nm, 'pid': pid, 'tid': ctid, 'ts': us(s), 'dur': max(0.001, us(e) - us(s))})
    VP = 1000000
    tracks = {'vsync': 1, 'notifications': 2, 'GPU': 3, 'scanout': 4, 'on screen': 5, 'touch': 6, 'present': 7}
    ev.append({'ph': 'M', 'name': 'process_name', 'pid': VP, 'args': {'name': 'display / GPU (0994)'}})
    for n, i in tracks.items():
        ev.append({'ph': 'M', 'name': 'thread_name', 'pid': VP, 'tid': i, 'args': {'name': n}})
    inst = lambda name, track, t, args=None: ev.append({'ph': 'i', 's': 't', 'name': name, 'pid': VP,
                                                         'tid': tracks[track], 'ts': us(t), 'args': args or {}})
    for e in sw['VSYNC']:
        inst(f'tick {e[3]} {"sent" if e[4] else "held"}', 'vsync', e[0], {'mode': e[5], 'panel frame': e[6]})
    for e in sw['VSYNC_SEND']:
        inst(f'vsync notification {e[3]} ({e[4]} clients)', 'notifications', e[0])
    for e in sw['NOTIFY']:
        if e[5]:
            inst(f'notification type {e[3]} DROPPED {e[5]:#x}', 'notifications', e[0])
    for e in sw['SWAPDONE']:
        inst(f'swap done ({ {1: "blit", 2: "CPU", 3: "latch"}.get(e[3], e[3]) })', 'notifications', e[0])
    owners = {}
    for f, (s, e, pid) in sorted(fences.items()):
        if pid not in owners:
            owners[pid] = next((v[1] for v in threads.values() if v[0] == pid), 'present' if pid == 0 else str(pid))
        ev.append({'ph': 'X', 'name': f'{owners[pid]} fence {f}', 'pid': VP, 'tid': tracks['GPU'], 'ts': us(s),
                   'dur': max(0.001, us(e) - us(s))})
    for e in sw['SCAN_FLIP']:
        inst(f'flip swap {e[3]}', 'scanout', e[0])
    lat = sorted(sw['SCAN_LATCH'])
    for i, e in enumerate(lat):
        inst(f'latched swap {e[3]}', 'scanout', e[0])
        end = lat[i + 1][0] if i + 1 < len(lat) else T.end_abs
        ev.append({'ph': 'X', 'name': f'swap {e[3]}', 'pid': VP, 'tid': tracks['on screen'], 'ts': us(e[0]),
                   'dur': us(end) - us(e[0])})
    for e in sw['TOUCH']:
        inst(f'touch {e[3]} {"down" if e[4] else "up"} {e[5]},{e[6]}', 'touch', e[0])
    for e in sw['SHOWN']:
        inst('shown (present)', 'present', e[0])
    with open(a.json, 'w') as f:
        json.dump({'traceEvents': ev, 'displayTimeUnit': 'ms'}, f)
    print(f'{a.json}: {len(ev)} trace events (open in ui.perfetto.dev)')


if __name__ == '__main__':
    main()
