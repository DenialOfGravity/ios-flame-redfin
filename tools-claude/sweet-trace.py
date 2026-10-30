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
  --chain      frame chain against the vsync ticks: app commits (bursts of app -> backboardd messages) -> arrival at the
               render server -> the tick and frame that used them (ticks skipped, phase), and each frame split into
               tick -> display wake -> CA prepare -> encode -> GPU -> present -> visible edge, with the display thread's
               on-CPU / blocked time (and its wakers) before the first submit
  --ipc        mach messages by msgh_id (MACH_IPC_MSG_SEND / RECV kdebug events): sender, receiving thread, rate,
               bytes, latency, receiver CPU
  --summary-json OUT  one JSON per test for the dashboard: frames, interval histogram (vsync periods), stage gaps,
               GPU ms per frame, largest-gap counts, the late-frame root-cause table (--pace), --chain and --ipc numbers
  --label NAME the test's label in the summary (default: the trace file name)
  --json also gets per-frame critical-path tracks, the app commits and msgh_id annotations on the receiving threads

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
    ap.add_argument('--chain', action='store_true')
    ap.add_argument('--ipc', action='store_true')
    ap.add_argument('--summary-json', metavar='OUT')
    ap.add_argument('--label')
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
    imsgs = []                 # [send abs, sender tid, kmsg, msgh_bits, msgh_id, send pid, dst pid, size, recv abs, receiver tid]
    ipc_pend = {}              # sender tid -> its last MACH_IPC_MSG_SEND waiting for the KMSG_INFO END (pids, size)
    ipc_inflight = {}          # kmsg -> the message, until a MACH_IPC_MSG_RECV of the same kmsg
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
            m = ipc_pend.pop(tid, None)
            if m is not None:
                m[5], m[6], m[7] = a1, a2, a3
        elif cid == IPC_SEND:
            # MACH_IPC_MSG_SEND: kmsg, msgh_bits, msgh_id, voucher (then KMSG_INFO END on the same thread: pids, size)
            m = [ts, tid, a1, a2 & 0xffffffff, a3 & 0xffffffff, None, None, None, None, None]
            imsgs.append(m)
            ipc_pend[tid] = m
            ipc_inflight[a1] = m
        elif cid == IPC_RECV or cid == IPC_RECV_NV:
            # MACH_IPC_MSG_RECV: kmsg, msgh_bits, msgh_id: the receiver of that kmsg (a kernel MIG reply reuses the
            # request's kmsg with id + 100: not matched)
            m = ipc_inflight.pop(a1, None)
            if m is not None and m[4] == (a3 & 0xffffffff):
                m[8], m[9] = ts, tid
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
    basics = {'frames': len(rows), 'stage_gaps_ms': {}}
    for x, y in PAIRS:
        v = [gap(st, x, y) for _, _, st, _ in rows]
        v = [g for g in v if g is not None]
        print(f'  {x:>12} -> {y:<12} {stats(v)}')
        basics['stage_gaps_ms'][f'{x} -> {y}'] = _st(v)
    for _, _, st, _ in rows:
        gs = [(gap(st, x, y), f'{x} -> {y}') for x, y in PAIRS]
        gs = [g for g in gs if g[0] is not None and g[0] > 0]
        if gs:
            dom[max(gs)[1]] += 1
    if dom:
        print('largest gap per frame:', ', '.join(f'{k} {n}x' for k, n in dom.most_common()))
    basics['largest_gap_counts'] = dict(dom.most_common())
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
            basics['gpu_ms'] = _st(g)
    if intervals:
        basics['onscreen_interval_ms'] = _st(intervals)
        basics['onscreen_interval_vsyncs'] = {f'{k}{"+" if k == 4 else ""}': v for k, v in sorted(per.items())}
    if disp:
        basics['display_thread_oncpu_ms'] = round(ms(T.start_abs + oncpu_abs[disp]), 1)
    if app_main:
        basics['app_main_oncpu_ms'] = round(ms(T.start_abs + oncpu_abs[app_main]), 1)

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

    PR = CH = ipc_rows = None
    if disp and (a.pace or a.chain or a.summary_json or a.json):
        PR = pace_report(a, T, threads, sw, calls, wakes, slices, msgs, fences, disp, app_main, bb, app, gpu_abs,
                         quiet=not a.pace)
    if PR and (a.chain or a.summary_json or a.json):
        CH = chain_report(a, T, threads, sw, calls, wakes, slices, imsgs, fences, disp, app_main, bb, app, PR,
                          quiet=not a.chain)
    if imsgs and (a.ipc or a.summary_json):
        ipc_rows = ipc_report(T, threads, imsgs, slices, bb | app | sb, quiet=not a.ipc)
    if a.summary_json:
        label = a.label or a.trace.rsplit('/', 1)[-1].rsplit('.', 1)[0]
        with open(a.summary_json, 'w') as f:
            json.dump(summary(a, T, label, basics, PR, CH, ipc_rows), f, indent=1)
        print(f'{a.summary_json}: summary written')

    if a.json:
        write_json(a, T, threads, slices, calls, sw, fences, bb, app, sb, wakes, tname, gpu_abs, imsgs, CH)


def pace_report(a, T, threads, sw, calls, wakes, slices, msgs, fences, disp, app_main, bb, app, gpu_abs, quiet=False):
    """--pace: which stage was running when the panel edge a late frame needed went by. Returns the frames, the late
    frames with their cause and the edge model (for --chain, --summary-json and --json); quiet: no printing."""
    pr = (lambda *x, **k: None) if quiet else print
    MS = T.abs_of_ns(1e6)            # 1 ms in absolute time units
    ms = lambda d: d / MS            # a duration in ms
    at = lambda t: T.ms(t)           # a time in ms from the trace start
    pr()
    pr('pacing (--pace)')
    if disp is None:
        pr('  no display thread: nothing to do')
        return None
    # ---- panel edges: VSYNC a4 = INTF1 frame counter when the tick ran (counts at each panel frame start) ----
    ticks = sorted((e[0], e[6], e[4]) for e in sw['VSYNC'] if e[6])          # (abs, frame counter, sent)
    if len(ticks) < 20:
        pr('  fewer than 20 vsync ticks with an INTF frame count: no edge model')
        return None
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
    pr(f'  panel period {Pms:.4f} ms ({1000 / Pms:.3f} Hz) from {n} ticks over frames {ticks[0][1]}-{ticks[-1][1]}; '
          f'tick after its edge: median {s_lag[n // 2]:.2f} p10 {s_lag[n // 10]:.2f} p90 {s_lag[n * 9 // 10]:.2f} ms; '
          f'tick to tick p10 {tick_iv[len(tick_iv) // 10]:.2f} median {tick_iv[len(tick_iv) // 2]:.2f} '
          f'p90 {tick_iv[len(tick_iv) * 9 // 10]:.2f} ms; notification period sent '
          f'{ms(sw["VSYNC_SEND"][0][6]):.3f} ms' if sw['VSYNC_SEND'] else '')
    opts = collections.Counter(e[5] >> 8 for e in sw['VSYNC'])
    lost = sum(1 for i in range(n - 1) if ticks[i + 1][1] - ticks[i][1] >= 2)
    pr(f'  ticks lost (the frame counter moved 2+ between two ticks): {lost} of {ticks[-1][1] - ticks[0][1]} edges; '
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
    # u-encthread (SWEET_ENCTHREAD=1): CA's frames are submitted to the GPU by backboardd's 'sweet.encthread' worker, which
    # replays the display thread's Metal calls: its submits (and scanout gates) count as the display thread's
    enc = [t for t, v in threads.items() if v[0] in bb and 'encthread' in (v[2] or '')]
    for t in enc:
        for s, e, c, sa, ea in calls.get(t, []):
            if c == 0x10:
                subs.append((s, e, ea[0]))
            elif c == 0x14:
                gates.append((s, e))
    if enc:
        pr(f'  encode worker (SWEET_ENCTHREAD): submits of tid {", ".join(str(t) for t in enc)} counted as the display thread\'s')
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
        # the swap's present. SHOWN (emitted right after the successful PRESENT END on the same thread, a1 = abs time
        # the copy landed) marks each present that reached the panel buffer; SWAPDONE (1 blit fence / 2 CPU copy) is
        # emitted only for some presents (e.g. 54 vs 173 SHOWN in hitch1-1029-195416), so it is the fallback when a
        # trace has no SHOWN events (older kernels)
        pres = []           # (end abs, tid, swap) of successful presents
        for tid, cl in calls.items():
            for s, e, c, sa, ea in cl:
                if c == 0x06 and not ea[1]:
                    pres.append((e, tid, sa[0]))
        pres.sort()
        if sw['SHOWN']:
            by_tid = collections.defaultdict(list)
            for e, tid, swap in pres:
                by_tid[tid].append((e, swap))
            for ev in sw['SHOWN']:
                pl = by_tid.get(ev[1], [])
                k = bisect.bisect_right(pl, (ev[0], float('inf'))) - 1
                if k < 0 or ev[0] - pl[k][0] > 5 * MS:
                    continue
                swap = pl[k][1]
                t = ev[3] if ev[3] and abs(ev[3] - ev[0]) < 5 * MS else ev[0]
                if swap not in flips or flips[swap][0] > t:
                    flips[swap] = (t, frame_at(t))
            path = 'present path: the first edge after the present\'s SHOWN (copy into the panel buffer)'
        else:
            done = sorted(e[0] for e in sw['SWAPDONE'] if e[3] in (1, 2))
            for e, tid, swap in pres:
                k = bisect.bisect_left(done, e)
                if k < len(done) and done[k] - e < 50 * MS:
                    t = done[k]
                    if swap not in flips or flips[swap][0] > t:
                        flips[swap] = (t, frame_at(t))
            path = 'present path: the first edge after the present\'s blit fence / copy (SWAPDONE, approximate)'
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
        pr('  no flips or presents with a swap id: nothing to do')
        return None
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
    cnt_idle = collections.Counter()    # late frames carrying the first app commit after > 200 ms (idle -> gesture)
    cnt_idle_sw = collections.Counter()
    IDLE = 200 * MS
    rate_by = collections.Counter()
    rate_by_sw = collections.Counter()
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
                        if sw_:
                            rate_by_sw[fr.get('Aw', '-')] += 1
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
            # idle start: this frame carries a new app commit that came > 200 ms after the app's previous commit (the
            # first frame after a gesture starts from idle): not app cadence, grouped on its own
            # (a frame without a new commit counts from the last commit before its SwapBegin)
            if new_commit:
                cgap = fr['C0'] - bursts[fr['Cb'] - 1][1] if fr['Cb'] > 0 else fr['C0'] - T.start_abs
            else:
                jj = bisect.bisect_right(b_first, fr['B']) - 1
                cgap = fr['B'] - (bursts[jj][1] if jj >= 0 else T.start_abs)
            if cgap > IDLE:
                cnt_idle[why] += 1
                if sw_:
                    cnt_idle_sw[why] += 1
        prev = fr
    tot = sum(ivs.values())
    pr(f'  frames by panel edge ({path}), idle gaps > 30 vsyncs left out: '
          + ', '.join(f'{k}{"+" if k == 4 else ""}v {ivs[k]}' for k in sorted(ivs)) + f' (of {tot})')
    tsw = sum(ivs_sw.values())
    pr(f'  during the {len(swin)} swipes (touch .. 700 ms after the finger left): '
          + ', '.join(f'{k}{"+" if k == 4 else ""}v {ivs_sw[k]}' for k in sorted(ivs_sw)) + f' (of {tsw})')
    # per-swipe frame rate: frames on the panel inside each swipe window / (last - first on-panel edge)
    swipe_fps = []
    for s0, s1 in swin:
        ns = [fr['n'] for fr in frames if s0 <= fr['F'] <= s1]
        if len(ns) >= 3 and ns[-1] > ns[0]:
            swipe_fps.append(round((len(ns) - 1) / ((ns[-1] - ns[0]) * Pms) * 1000, 1))
    if swipe_fps:
        pr(f'    fps per swipe (frames on the panel / their edge span): {", ".join(f"{x:.1f}" for x in swipe_fps)}; late '
              f'intervals (2v+) during swipes {sum(v for k, v in ivs_sw.items() if k >= 2)}')
    if gpu_sw:
        gpu_sw.sort()
        pr(f'    GPU per swipe frame: median {gpu_sw[len(gpu_sw) // 2]:.2f} p10 {gpu_sw[len(gpu_sw) // 10]:.2f} '
              f'p90 {gpu_sw[len(gpu_sw) * 9 // 10]:.2f} ms; >= 0.8 period {sum(1 for x in gpu_sw if x >= 0.8 * Pms)} '
              f'of {len(gpu_sw)}')
    pr('  late frames (2v or more): the stage running when the missed edge went by')
    pr(f'    {"cause":10s} {"all":>5} {"2v":>5} {"3v":>5} {"4+v":>5} {"swipe":>5}  meaning')
    for k, txt in CAUSES.items():
        if cnt[k]:
            pr(f'    {k:10s} {cnt[k]:5d} {by_iv[2][k]:5d} {by_iv[3][k]:5d} {by_iv[4][k]:5d} {cnt_sw[k]:5d}  {txt}')
    if cnt_idle:
        pr(f'    idle start: {sum(cnt_idle.values())} of these (swipe {sum(cnt_idle_sw.values())}) carry the first app commit '
              f'after > 200 ms idle (' + ', '.join(f'{k} {v}' for k, v in cnt_idle.most_common()) +
              '); --summary-json groups them as "idle start", not app cadence')
    if rate_by:
        pr('    app_rate by what woke the app main thread for that commit: ' +
              ', '.join(f'{k} {v}' for k, v in rate_by.most_common()) +
              ' (timer: CADisplayLink, anim: UIKit inProcessAnimationManager, touch: eventfetch)')
    if gate_gap:
        gate_gap.sort()
        pr(f'    GPU late: previous frame\'s GPU done -> this frame\'s GPU start (held for the previous latch, 2 '
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
        pr(f'  latch (swap-done) - nearest tick: median {rel[len(rel) // 2]:+.2f} p10 {rel[len(rel) // 10]:+.2f} p90 '
              f'{rel[len(rel) * 9 // 10]:+.2f} ms; latch after the tick {sum(1 for x in rel if x > 0)} of {len(rel)}')
    ll = sorted(ms(fr['L'] - edge(fr['n'], fr['L'])) for fr in frames if fr.get('L') is not None)
    if ll:
        pr(f'  latch seen after its edge: median {ll[len(ll) // 2]:.2f} p10 {ll[len(ll) // 10]:.2f} p90 '
              f'{ll[len(ll) * 9 // 10]:.2f} max {ll[-1]:.2f} ms (the scanout thread polls every 1 ms; the gate opens then)')
    swb = sorted(ms(e - s) for s, e, _ in swapwaits if e - s > 0.05 * MS)
    gw = sorted(ms(e - s) for s, e in gates)
    pr(f'  display thread: SwapWait blocked {len(swb)} of {len(swapwaits)} calls'
          + (f' (median {swb[len(swb) // 2]:.2f} max {swb[-1]:.2f} ms)' if swb else '')
          + f'; scanout gate held the submit {len(gw)} times' + (f' (median {gw[len(gw) // 2]:.2f} p90 '
                                                                 f'{gw[len(gw) * 9 // 10]:.2f} ms)' if gw else ''))
    g = sorted(fr['gpu'] for fr in frames if fr['gpu'] is not None and fr['newsub'])
    if g:
        pr(f'  GPU per frame (frames with a new submit): median {g[len(g) // 2]:.2f} p90 {g[len(g) * 9 // 10]:.2f} '
              f'ms; >= 0.8 period: {sum(1 for x in g if x >= 0.8 * Pms)} of {len(g)}')
    # chain timings relative to the frame's own edge for on-time frames vs late ones
    if a.pace_frames:
        pr(f'  first {a.pace_frames} late frames: times in ms relative to the missed edge (A app tick, C commit end, '
              'V bb tick used, B SwapBegin, S0/S1 submit start/end (gate), G GPU done, SE SwapEnd, F flip)')
        for fr, pv, D, why, dn in [x for x in late if not a.pace_swipes or in_sw(x[0]['F'])][:a.pace_frames]:
            r = lambda x: f'{ms(x - D):7.2f}' if x is not None else f'{"-":>7}'
            pr(f'    {at(fr["F"]):9.1f} swap {fr["swap"]:#x} {dn}v {why:9s} prevSE {r(pv["SE"])} A {r(fr.get("A"))} '
                  f'({fr.get("Aw", "-"):5s}) C {r(fr["C"])} V {r(fr["V"])} B {r(fr["B"])} S0 {r(fr["S0"])} '
                  f'S1 {r(fr["S1"])} G {r(fr["G"])} SE {r(fr["SE"])} F {r(fr["F"])} gpu '
                  f'{fr["gpu"] if fr["gpu"] is not None else -1:5.2f}')

    # ---- phases against the panel edges over time ----
    def phase(t):
        f = frame_at(t)
        return ms(t - edge(f, t))
    app_ticks = [w[0] for w in aw if wclass(w) == 'timer']
    commits = [b[1] for b in bursts]
    pr(f'  phase after the last panel edge (0..{Pms:.2f} ms), per 500 ms: app timer wakes of the main thread '
          '(CADisplayLink), app commit ends, backboardd ticks')
    pr(f'    {"t ms":>7} {"app n":>5} {"app ph":>7} {"commit n":>8} {"commit ph":>9} {"bb tick ph":>10}')
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
        pr(f'    {b * 500:7d} {len(ap_):5d} {f_(m1)} {len(cp_):8d} {f_(m2):>9} {f_(m3):>10}')
    # drift of the app timer against the panel: consecutive app timer wakes ~1 period apart
    d = []
    app_period = None
    for i in range(len(app_ticks) - 1):
        iv = ms(app_ticks[i + 1] - app_ticks[i])
        if 0.5 * Pms < iv < 1.5 * Pms:
            d.append(iv)
    if d:
        d.sort()
        dm = d[len(d) // 2]
        app_period = dm
        slope = (dm - Pms) / Pms * 1000
        pr(f'  app timer period median {dm:.4f} ms ({len(d)} intervals) vs panel {Pms:.4f} ms: phase moves '
              f'{slope:+.2f} ms per second, one full period every {abs(Pms / slope) if slope else float("inf"):.1f} s')
    return {'frames': frames, 'late': late, 'cnt': cnt, 'by_iv': by_iv, 'cnt_sw': cnt_sw, 'ivs': ivs, 'ivs_sw': ivs_sw,
            'in_sw': in_sw, 'swin': swin, 'P': P, 'Pms': Pms, 'edge': edge, 'frame_at': frame_at, 'bursts': bursts,
            'vsend': vsend, 'gpu_sw': gpu_sw, 'rate_by': rate_by, 'rate_by_sw': rate_by_sw, 'CAUSES': CAUSES,
            'app_period': app_period, 'cnt_idle': cnt_idle, 'cnt_idle_sw': cnt_idle_sw,
            'swipe_fps': swipe_fps, 'tick_lag': s_lag[n // 2], 'path': path, 'gate_gap': gate_gap,
            'swapwaits': swapwaits, 'subs': subs, 'sbegin': sbegin, 'send_': send_, 'swap_fence': swap_fence,
            'flips': flips}


MSG_IDS = {0: 'empty message (mk_timer / port wake-up)', 53: 'IOKit notification (kOSNotificationMessageID: IOMFB vsync)',
           57: 'IOKit async completion', 70: 'MACH_NOTIFY_NO_SENDERS', 71: 'MACH_NOTIFY_SEND_ONCE',
           72: 'MACH_NOTIFY_DEAD_NAME', 2865: 'IOKit io_connect_method', 2866: 'IOKit io_connect_async_method',
           40002: 'QuartzCore client -> render server (CAContext commit / update)',
           0x10000000: 'XPC message', 0x10000004: 'XPC reply', 0x40000000: 'XPC / libdispatch mach channel'}


def msg_name(i):
    """a short name for a msgh_id (MIG subsystem ranges; only the ids seen in the redfin traces are named exactly)"""
    if i in MSG_IDS:
        return MSG_IDS[i]
    for lo, hi, nm in ((200, 300, 'mach_host'), (400, 500, 'host_priv'), (2800, 3000, 'IOKit MIG'),
                       (3200, 3300, 'mach_port'), (3300, 3400, 'mach_port reply'), (3400, 3600, 'task'),
                       (3600, 3800, 'thread_act'), (4800, 5000, 'mach_vm'), (40000, 41000, 'QuartzCore MIG'),
                       (0x10000000, 0x10000100, 'XPC')):
        if lo <= i < hi:
            return f'{nm} {i}'
    return f'id {i}'


def _pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * q))] if v else None


def _st(v):
    """{n, median, p90, mean} of a list (None entries dropped)"""
    v = sorted(x for x in v if x is not None)
    if not v:
        return {'n': 0}
    return {'n': len(v), 'median': round(v[len(v) // 2], 3), 'p90': round(_pct(v, 0.9), 3),
            'mean': round(sum(v) / len(v), 3), 'max': round(v[-1], 3)}


def _sts(d):
    if not d.get('n'):
        return 'n    0'
    return f'n {d["n"]:4d} median {d["median"]:7.2f} p90 {d["p90"]:7.2f} mean {d["mean"]:7.2f}'


def ipc_report(T, threads, imsgs, slices, focus_pids, quiet=False, top=25):
    """--ipc: mach messages with their msgh_id (MACH_IPC_MSG_SEND), sender (KMSG_INFO) and receiving thread
    (MACH_IPC_MSG_RECV of the same kmsg). Receiver cost = on-CPU time of the receiving thread from the receive until it
    blocks again (all messages handled in that run share it)."""
    pr = (lambda *x, **k: None) if quiet else print
    MS = T.abs_of_ns(1e6)
    span_s = (T.end_abs - T.start_abs) / MS / 1000

    def pn(p):
        if p is None:
            return '?'
        for v in threads.values():
            if v[0] == p:
                return v[1]
        return 'kernel' if p == 0 else f'pid {p}'

    def tn(t):
        v = threads.get(t)
        return f'{v[1]}/{v[2] or t}' if v else f'tid {t}'
    run = {t: sorted((s, e) for s, e, k, _ in sl if k == 'running') for t, sl in slices.items()}

    def run_left(t, ts):
        r = run.get(t)
        if not r:
            return None
        i = bisect.bisect_right(r, (ts, float('inf'))) - 1
        if i >= 0 and r[i][0] <= ts <= r[i][1]:
            return r[i]
        return None
    groups = collections.defaultdict(lambda: {'n': 0, 'bytes': 0, 'lat': [], 'runs': set(), 'recv': 0})
    for m in imsgs:
        if m[5] is None or not (m[5] in focus_pids or m[6] in focus_pids):
            continue
        if m[6] == 0 and m[9] is None:
            continue        # MIG calls into the kernel: not messages between processes
        key = (pn(m[5]), m[4], pn(m[6]), tn(m[9]) if m[9] else '-')
        g = groups[key]
        g['n'] += 1
        g['bytes'] += m[7] or 0
        if m[8] is not None:
            g['recv'] += 1
            g['lat'].append((m[8] - m[0]) / MS)
            r = run_left(m[9], m[8])
            if r:
                g['runs'].add((m[9], r[0], r[1]))
    rows = []
    for (s, i, d, rt), g in groups.items():
        cpu = sum(e - st for _, st, e in g['runs']) / MS
        rows.append({'sender': s, 'id': i, 'name': msg_name(i), 'dst': d, 'receiver': rt, 'count': g['n'],
                     'per_s': round(g['n'] / span_s, 1), 'bytes': g['bytes'], 'latency_ms': _st(g['lat']),
                     'receiver_runs': len(g['runs']), 'receiver_cpu_ms': round(cpu, 2)})
    rows.sort(key=lambda r: -r['count'])
    pr()
    pr(f'mach messages by msgh_id (--ipc; {len(imsgs)} sends with an id; involving '
       f'{", ".join(sorted({pn(p) for p in focus_pids}))}); receiver CPU = on-CPU runs of the receiving thread that '
       'contain the receive (shared by the messages handled in one run)')
    pr(f'  {"count":>6} {"/s":>6} {"bytes":>8} {"lat med":>7}  {"rcv cpu ms":>10}  sender -> receiver thread: id (name)')
    for r in rows[:top]:
        lm = r['latency_ms'].get('median')
        pr(f'  {r["count"]:6d} {r["per_s"]:6.0f} {r["bytes"]:8d} {lm if lm is not None else -1:7.3f}  '
           f'{r["receiver_cpu_ms"]:10.1f}  {r["sender"]} -> {r["receiver"]}: {r["id"]} ({r["name"]})')
    return rows


def chain_report(a, T, threads, sw, calls, wakes, slices, imsgs, fences, disp, app_main, bb, app, PR, quiet=False):
    """--chain: the frame chain against the vsync ticks. App commits (the app main thread's bursts of messages to
    backboardd, with their arrival at the receiving render-server thread) -> the tick and the display-thread frame that
    used them (how many ticks they waited), and each frame split into tick -> wake -> SwapBegin (CA prepare) -> first
    GPU submit (encode) -> GPU done -> SwapEnd -> on the panel, with the display thread's on-CPU / blocked time (and
    who woke it) between its wake and the first submit."""
    pr = (lambda *x, **k: None) if quiet else print
    MS = T.abs_of_ns(1e6)
    ms = lambda d: d / MS
    P, Pms, edge = PR['P'], PR['Pms'], PR['edge']
    vsend = PR['vsend']
    # every display-thread frame (SwapEnd), also those replaced on the panel by a later one for the same edge
    frames = []
    subs = PR['subs']
    for swap, (s0, s1) in PR['send_'].items():
        b = PR['sbegin'].get(swap) or s0
        i = bisect.bisect_right(vsend, b) - 1
        fr = {'swap': swap, 'B': b, 'SE': s1, 'V': vsend[i] if i >= 0 else None, 'S0': None, 'S1': None}
        k = bisect.bisect_left(subs, (b,))
        if k < len(subs) and subs[k][0] <= s1:
            fr['S0'], fr['S1'] = subs[k][0], subs[k][1]
        fr['newsub'] = fr['S0'] is not None
        fe = fences.get(PR['swap_fence'].get(swap))
        fr['G'] = fe[1] if fe else None
        fr['gpu'] = ms(fe[1] - fe[0]) if fe else None
        # all of the display thread's submits for this frame (offscreen passes + the final one)
        fs = [fences[x[2]] for x in subs[k:bisect.bisect_right(subs, (s1, float('inf')))] if x[2] in fences]
        fr['nsub'] = len(fs)
        fr['gpu_all'] = ms(sum(e - st for st, e, _ in fs)) if fs else None
        if fs and fe is None:
            fr['G'] = max(e for _, e, _ in fs)
        fl = PR['flips'].get(swap)
        fr['F'], fr['n'] = (fl[0], fl[1] + 1) if fl else (None, None)
        frames.append(fr)
    frames.sort(key=lambda f: f['B'])
    shown = {f['swap'] for f in PR['frames']}
    for f in frames:
        f['shown'] = f['swap'] in shown

    def tn(t):
        v = threads.get(t)
        return f'{v[1]}/{v[2] or t}' if v else f'tid {t}'

    def short(t, irq=False):
        v = threads.get(t, [0, '?', ''])
        nm = v[2] or ''
        if irq:
            return 'irq'
        if 'thread call' in nm:
            return 'timer/tick'
        if v[1] == 'kernel_task':
            return 'kernel'
        return f'{v[1]}/{nm or t}'
    # ---- the display thread's frames: its wake after the tick, split of wake -> first submit ----
    dwk = wakes.get(disp, [])
    dwt = [w[0] for w in dwk]
    dsl = sorted(slices.get(disp, []))
    dst = [x[0] for x in dsl]
    dcalls = sorted(calls.get(disp, []))
    for fr in frames:
        lo = fr['V'] if fr['V'] is not None else fr['B'] - 20 * MS
        i = bisect.bisect_left(dwt, lo)
        fr['W'] = dwt[i] if i < len(dwt) and dwt[i] <= fr['B'] else (fr['V'] or fr['B'])
        fr['Wby'] = short(dwk[i][2], dwk[i][3]) if i < len(dwt) and dwt[i] <= fr['B'] else '-'
    # the frame's start: the display thread's wake after its last idle block (>= 1 ms) since the previous SwapEnd, or
    # the previous SwapEnd itself when it did not go idle in between (it went straight on to this frame)
    prev_se = None
    for fr in frames:
        fr['start'], fr['startby'] = fr['W'], 'tick' if fr['Wby'] == 'timer/tick' else fr['Wby']
        if prev_se is not None and prev_se < fr['B']:
            j = max(0, bisect.bisect_right(dst, prev_se) - 1)
            idle = None
            while j < len(dsl) and dsl[j][0] < fr['B']:
                s_, e_, kd, w = dsl[j]
                if kd == 'blocked' and e_ > prev_se and e_ - max(s_, prev_se) >= 1 * MS:
                    idle = dsl[j]
                j += 1
            if idle is None:
                fr['start'], fr['startby'] = prev_se, 'went on from the previous SwapEnd'
            else:
                i = bisect.bisect_left(dwt, idle[1] - 0.01 * MS)
                if i < len(dwt) and dwt[i] <= fr['B']:
                    fr['start'] = dwt[i]
                    fr['startby'] = 'tick' if short(dwk[i][2], dwk[i][3]) == 'timer/tick' else short(dwk[i][2], dwk[i][3])
                else:
                    fr['start'] = idle[1]
        prev_se = fr['SE']
    for fr in frames:
        end = fr['S0'] or fr['SE']
        split = collections.Counter()
        blk = collections.Counter()
        j = max(0, bisect.bisect_right(dst, fr['start']) - 1)
        while j < len(dsl) and dsl[j][0] < end:
            s, e, kind, w = dsl[j]
            d = min(e, end) - max(s, fr['start'])
            if d > 0:
                split[kind] += d
                if kind == 'blocked' and w:
                    blk[short(w[1], w[2])] += d
            j += 1
        fr['split'] = {k: ms(v) for k, v in split.items()}
        fr['blk'] = {k: ms(v) for k, v in blk.items()}
        k = bisect.bisect_left(dcalls, (fr['start'],))
        big = []
        while k < len(dcalls) and dcalls[k][0] < end:
            c = dcalls[k]
            if c[1] - c[0] > 0.5 * MS:
                nm = (IOMFB_SEL_NAMES.get(c[3][0], f'IOMFB {c[3][0]}') if c[2] == 0x04 else
                      'accel ' + ACCEL_NAMES.get(c[3][0], str(c[3][0])) if c[2] == 0x15 else
                      {0x10: 'GPU submit', 0x12: 'GPU wait', 0x14: 'gate'}.get(c[2], hex(c[2])))
                big.append((nm, ms(c[1] - c[0])))
            k += 1
        fr['bigcalls'] = big
    # ---- app commits ----
    cm = sorted((m for m in imsgs if m[5] in app and m[6] in bb and (app_main is None or m[1] == app_main)),
                key=lambda m: m[0])
    commits = []
    for m in cm:
        if commits and m[0] - commits[-1]['s1'] < 0.5 * MS:
            c = commits[-1]
        else:
            c = {'s0': m[0], 's1': m[0], 'n': 0, 'bytes': 0, 'big': 0, 'arr': None, 'rtid': None}
            commits.append(c)
        c['s1'] = m[0]
        c['n'] += 1
        c['bytes'] += m[7] or 0
        c['big'] = max(c['big'], m[7] or 0)
        if m[8] is not None and (c['arr'] is None or m[8] > c['arr']):
            c['arr'], c['rtid'] = m[8], m[9]
    commits = [c for c in commits if (c['n'] >= 3 or c['big'] >= 500) and c['arr'] is not None]
    run = {}
    aw = wakes.get(app_main, []) if app_main else []
    awt = [w[0] for w in aw]
    fb = [f['B'] for f in frames]
    for c in commits:
        t = c['rtid']
        if t not in run:
            run[t] = sorted((s, e) for s, e, kd, _ in slices.get(t, []) if kd == 'running')
        r = run[t]
        i = bisect.bisect_right(r, (c['arr'], float('inf'))) - 1
        c['done'] = r[i][1] if i >= 0 and r[i][0] <= c['arr'] <= r[i][1] else c['arr']
        i = bisect.bisect_right(vsend, c['arr']) - 1
        c['ptick'] = vsend[i] if i >= 0 else None
        c['ntick'] = vsend[i + 1] if i + 1 < len(vsend) else None
        c['phase'] = ms(c['arr'] - c['ptick']) if c['ptick'] is not None else None
        j = bisect.bisect_right(awt, c['s0']) - 1
        c['why'] = '-'
        if j >= 0 and c['s0'] - awt[j] < 30 * MS:
            w = aw[j]
            nm = threads.get(w[2], [0, '?', ''])[2] or ''
            c['why'] = ('irq' if w[3] else 'timer' if 'thread call' in nm else 'anim' if 'inProcessAnimation' in nm
                        else 'touch' if 'eventfetch' in nm else 'other')
        k = bisect.bisect_right(fb, c['done'])
        c['frame'] = frames[k] if k < len(frames) and frames[k]['B'] - c['done'] < 100 * MS else None
        if c['frame'] is not None and c['ntick'] is not None:
            fr = c['frame']
            c['wait'] = ms(max(fr['W'], fr['start']) - c['arr'])
            c['tick_wait'] = ms(c['ntick'] - c['arr'])
            v = fr['V'] or fr['W']
            c['late_ticks'] = max(0, bisect.bisect_right(vsend, v) - bisect.bisect_left(vsend, c['ntick']) - 1) \
                if v >= c['ntick'] else -1
            c['to_screen'] = ms(edge(fr['n'], fr['F']) - c['arr']) if fr.get('n') is not None else None
            c['frame_gpu'] = fr['gpu'] if fr['newsub'] else None
            if c['late_ticks'] >= 1:
                # why the first tick after the arrival did not take it: the display thread at that tick
                t = c['ntick']
                k = bisect.bisect_left(fb, t) - 1
                pf = frames[k] if k >= 0 else None
                if pf is not None and pf['SE'] >= t:
                    if t < pf['B']:
                        c['skip'] = 'busy: previous frame CA prepare'
                    elif pf['S0'] is None or t < pf['S0']:
                        c['skip'] = 'busy: previous frame encode'
                    elif t < pf['S1']:
                        c['skip'] = 'busy: previous frame GPU submit held (scanout gate)'
                    else:
                        c['skip'] = 'busy: previous frame after submit (SwapEnd)'
                else:
                    i = bisect.bisect_left(dwt, t)
                    woke = i < len(dwt) and dwt[i] - t < 1 * MS
                    st = 'blocked'
                    j = bisect.bisect_right(dst, t) - 1
                    if j >= 0 and dsl[j][0] <= t <= dsl[j][1]:
                        st = dsl[j][2]
                    c['skip'] = ('idle: woke at the tick, no frame' if woke else
                                 'idle: not woken by the tick' if st == 'blocked' else
                                 'busy: display thread running (CA prepare of a frame begun before the commit '
                                 'arrived, or post-frame work)' if st == 'running' else f'display thread {st} at the tick')
    # ---- report ----
    R = {'commits': len(commits)}
    R['commit_msgs'] = _st([c['n'] for c in commits])
    R['commit_bytes'] = _st([c['bytes'] for c in commits])
    R['commit_send'] = _st([ms(c['s1'] - c['s0']) for c in commits])
    R['commit_ipc'] = _st([ms(c['arr'] - c['s1']) for c in commits])
    R['commit_decode'] = _st([ms(c['done'] - c['arr']) for c in commits])
    R['commit_phase'] = _st([c['phase'] for c in commits])
    R['commit_wait'] = _st([c.get('wait') for c in commits])
    R['commit_tick_wait'] = _st([c.get('tick_wait') for c in commits])
    R['commit_to_screen'] = _st([c.get('to_screen') for c in commits])
    lt = collections.Counter(c.get('late_ticks') for c in commits if c.get('late_ticks') is not None)
    R['late_ticks'] = {str(k): v for k, v in sorted(lt.items())}
    ph = collections.Counter(min(int(c['phase']), int(Pms)) for c in commits if c['phase'] is not None)
    R['phase_hist_ms'] = [ph.get(i, 0) for i in range(int(Pms) + 1)]
    R['commit_by_waker'] = dict(collections.Counter(c['why'] for c in commits))
    R['_skip_examples'] = [(T.ms(c['ntick']), c['skip']) for c in commits if 'skip' in c][:12]
    R['skipped_tick_reason'] = dict(collections.Counter(c['skip'] for c in commits if 'skip' in c).most_common())
    # frames
    def g(fr, x, y):
        return ms(fr[y] - fr[x]) if fr.get(x) is not None and fr.get(y) is not None else None
    for fr in frames:
        fr['E'] = edge(fr['n'], fr['F']) if fr['n'] is not None else None
    st = collections.OrderedDict()
    st['tick -> display wake'] = [g(f, 'V', 'W') for f in frames]
    st['frame start -> SwapBegin (CA prepare)'] = [g(f, 'start', 'B') for f in frames]
    st['SwapBegin -> 1st submit (encode)'] = [g(f, 'B', 'S0') for f in frames]
    st['wake -> 1st submit'] = [g(f, 'W', 'S0') for f in frames]
    st['frame start -> 1st submit (CPU)'] = [g(f, 'start', 'S0') for f in frames]
    st['1st submit call (scanout gate)'] = [g(f, 'S0', 'S1') for f in frames]
    st['1st submit -> GPU done'] = [g(f, 'S0', 'G') for f in frames]
    st['wake -> SwapEnd'] = [g(f, 'W', 'SE') for f in frames]
    st['SwapEnd -> on panel (present/flip)'] = [g(f, 'SE', 'F') for f in frames]
    st['on panel -> visible edge'] = [g(f, 'F', 'E') for f in frames]
    st['tick -> visible edge'] = [g(f, 'V', 'E') for f in frames]
    R['stages'] = {k: _st(v) for k, v in st.items()}
    sp = collections.defaultdict(list)
    bk = collections.Counter()
    for f in frames:
        for k in ('running', 'blocked', 'runnable', 'preempted'):
            sp[k].append(f['split'].get(k, 0.0))
        for k, v in f['blk'].items():
            bk[k] += v
    R['start_to_submit_split'] = {k: _st(v) for k, v in sp.items()}
    # the display thread's CPU: inside frames (wake -> SwapEnd) and outside them
    tot = sum(e - s for s, e, kd, _ in dsl if kd == 'running')
    inside = 0
    for f in frames:
        j = max(0, bisect.bisect_right(dst, f['W']) - 1)
        while j < len(dsl) and dsl[j][0] < f['SE']:
            s, e, kd, _ = dsl[j]
            if kd == 'running':
                inside += max(0, min(e, f['SE']) - max(s, f['W']))
            j += 1
    post = 0
    post_calls = collections.Counter()
    for i, f in enumerate(frames):
        nxt = frames[i + 1]['W'] if i + 1 < len(frames) else T.end_abs
        j = max(0, bisect.bisect_right(dst, f['SE']) - 1)
        while j < len(dsl) and dsl[j][0] < nxt:
            s, e, kd, _ = dsl[j]
            if kd == 'running':
                post += max(0, min(e, nxt) - max(s, f['SE']))
            j += 1
        k = bisect.bisect_left(dcalls, (f['SE'],))
        while k < len(dcalls) and dcalls[k][0] < nxt:
            c = dcalls[k]
            nm = (IOMFB_SEL_NAMES.get(c[3][0], f'IOMFB {c[3][0]}') if c[2] == 0x04 else
                  'accel ' + ACCEL_NAMES.get(c[3][0], str(c[3][0])) if c[2] == 0x15 else
                  {0x10: 'GPU submit', 0x12: 'GPU wait', 0x14: 'gate'}.get(c[2], hex(c[2])))
            post_calls[nm] += c[1] - c[0]
            k += 1
    R['display_oncpu_ms'] = {'total': round(ms(tot), 1), 'in_frames': round(ms(inside), 1),
                             'per_frame': round(ms(inside) / max(1, len(frames)), 2),
                             'after_swapend': round(ms(post), 1),
                             'after_swapend_per_frame': round(ms(post) / max(1, len(frames)), 2)}
    R['after_swapend_kernel_calls_ms'] = {k: round(ms(v), 1) for k, v in post_calls.most_common(6)}
    # when does the display thread first block (or get preempted) after SwapEnd, against its frame's GPU done?
    # (a busy wait for the GPU shows as running until the fence ends: block - GPU done ~ 0)
    rel = []
    for f in frames:
        if f['G'] is None:
            continue
        j = bisect.bisect_right(dst, f['SE'])
        while j < len(dsl) and dsl[j][2] == 'running':
            j += 1
        if j < len(dsl) and dsl[j][0] - f['SE'] < 100 * MS:
            rel.append((ms(dsl[j][0] - f['SE']), ms(dsl[j][0] - f['G'])))
    R['after_swapend_run_ms'] = _st([x[0] for x in rel])
    R['after_swapend_block_minus_gpu_done_ms'] = _st([x[1] for x in rel])
    R['after_swapend_block_within_1ms_of_gpu_done'] = sum(1 for x in rel if abs(x[1]) < 1)
    R['after_swapend_frames'] = len(rel)
    R['blocked_on_ms_total'] = {k: round(v, 1) for k, v in bk.most_common(8)}
    R['display_woken_by'] = dict(collections.Counter(f['Wby'] for f in frames).most_common(8))
    R['frame_started_by'] = dict(collections.Counter(f['startby'] for f in frames).most_common(8))
    R['gpu_ms'] = _st([f['gpu'] for f in frames if f['newsub']])
    R['gpu_all_submits_ms'] = _st([f['gpu_all'] for f in frames if f['newsub']])
    R['submits_per_frame'] = _st([f['nsub'] for f in frames if f['newsub']])
    long_ = [f for f in frames if f['S0'] is not None and ms(f['S0'] - f['start']) > 20]
    R['long_frames_start_submit_gt20ms'] = len(long_)
    lc = collections.Counter()
    for f in long_:
        for nm, d in f['bigcalls']:
            lc[nm] += 1
    R['long_frame_calls'] = dict(lc.most_common(8))
    R['long_frames'] = [{'t_ms': round(T.ms(f['start']), 1), 'cpu_ms': round(ms(f['S0'] - f['start']), 2),
                         'split': {k: round(v, 2) for k, v in f['split'].items()}, 'started_by': f['startby'],
                         'gpu_ms': round(f['gpu_all'], 2) if f['gpu_all'] else None,
                         'interval_before_ms': round(ms(f['start'] - frames[i - 1]['SE']), 1) if i else None}
                        for i, f in enumerate(frames) if f in long_][:20]
    # scaling: encode / prepare against the GPU time (work proxy) and the commit size
    sc = []
    for f in frames:
        if f['S0'] is not None and f['gpu'] is not None and f['newsub']:
            sc.append((f['gpu_all'] or f['gpu'], ms(f['S0'] - f['B']), ms(f['B'] - f['start'])))
    bins = [(0, 1), (1, 5), (5, 12), (12, 100)]
    R['encode_by_gpu_ms'] = {f'{lo}-{hi}': {'n': len(v), 'encode_median': _st([x[1] for x in v]).get('median'),
                                           'prepare_median': _st([x[2] for x in v]).get('median')}
                             for lo, hi in bins for v in [[x for x in sc if lo <= x[0] < hi]]}
    sw_frames = [f for f in frames if PR['in_sw'](f['B'])]
    R['frames'] = len(frames)
    R['frames_replaced_or_not_shown'] = sum(1 for f in frames if not f['shown'])
    R['gpu_by_commit_waker'] = {k: _st([c.get('frame_gpu') for c in commits if c['why'] == k])
                                for k in sorted({c['why'] for c in commits})}
    pg = []
    for f, (s, e, pid) in fences.items():
        if pid == 0:
            pg.append(ms(e - s))
    R['present_blit_gpu_ms'] = _st(pg)
    R['swipe_frames'] = len(sw_frames)
    R['swipe_gpu_ms'] = _st([f['gpu'] for f in sw_frames if f['newsub']])
    R['swipe_gpu_all_submits_ms'] = _st([f['gpu_all'] for f in sw_frames if f['newsub']])
    # GPU busy share during swipes: the union of all fences (any process) inside the swipe windows
    iv = sorted((st, e) for st, e, _ in fences.values())
    busy = tot_sw = 0
    for w0, w1 in PR['swin']:
        w1 = min(w1, T.end_abs)
        tot_sw += max(0, w1 - w0)
        cur = None
        for st, e in iv:
            st, e = max(st, w0), min(e, w1)
            if e <= st:
                continue
            if cur and st <= cur[1]:
                cur[1] = max(cur[1], e)
            else:
                if cur:
                    busy += cur[1] - cur[0]
                cur = [st, e]
        if cur:
            busy += cur[1] - cur[0]
    R['swipe_gpu_busy_pct'] = round(100 * busy / tot_sw, 1) if tot_sw else None
    R['swipe_stages'] = {k: _st([g(f, *xy) for f in sw_frames]) for k, xy in
                         (('wake -> 1st submit', ('W', 'S0')), ('frame start -> 1st submit (CPU)', ('start', 'S0')),
                          ('1st submit call (scanout gate)', ('S0', 'S1')), ('1st submit -> GPU done', ('S0', 'G')),
                          ('tick -> visible edge', ('V', 'E')))}
    swc = [c for c in commits if PR['in_sw'](c['arr'])]
    R['swipe_commit_wait'] = _st([c.get('wait') for c in swc])
    R['swipe_commit_to_screen'] = _st([c.get('to_screen') for c in swc])
    R['swipe_commit_rate_hz'] = None
    if PR['swin']:
        dur = sum(min(s1, T.end_abs) - s0 for s0, s1 in PR['swin']) / MS / 1000
        R['swipe_commit_rate_hz'] = round(len(swc) / dur, 1) if dur > 0 else None
    pr()
    pr('frame chain (--chain): app commits -> backboardd tick -> frame -> panel; all times in ms')
    pr(f'  {len(commits)} app commits (bursts of app main thread -> backboardd messages): messages per commit '
       f'{_sts(R["commit_msgs"])}; bytes {_sts(R["commit_bytes"])}')
    pr(f'  commit send burst {_sts(R["commit_send"])}; last send -> received {_sts(R["commit_ipc"])}; '
       f'receiver decode (run until it blocks) {_sts(R["commit_decode"])}')
    pr(f'  commit arrival after the previous bb tick (phase): {_sts(R["commit_phase"])}; histogram per ms: '
       f'{R["phase_hist_ms"]}')
    pr(f'  arrival -> next tick {_sts(R["commit_tick_wait"])}; arrival -> display wake of the frame that used it '
       f'{_sts(R["commit_wait"])}; ticks skipped after the first: {R["late_ticks"]}')
    pr(f'  arrival -> visible on the panel {_sts(R["commit_to_screen"])}; commits by app waker: {R["commit_by_waker"]}')
    pr(f'  commits not taken by the first tick after them, the display thread at that tick: {R["skipped_tick_reason"]}')
    if R['swipe_commit_rate_hz'] is not None:
        pr(f'  during swipes: {len(swc)} commits, {R["swipe_commit_rate_hz"]} per s; arrival -> display wake '
           f'{_sts(R["swipe_commit_wait"])}; arrival -> visible {_sts(R["swipe_commit_to_screen"])}')
    pr(f'  {len(frames)} display frames ({R["frames_replaced_or_not_shown"]} replaced before the panel showed them / not '
       f'shown); display thread woken by {R["display_woken_by"]}')
    pr(f'  GPU per frame by what woke the app for the commit it carried: ' +
       '; '.join(f'{k} {_sts(v)}' for k, v in R['gpu_by_commit_waker'].items()))
    pr(f'  present-path blits (kernel GPU work, pid 0): {_sts(R["present_blit_gpu_ms"])}')
    for k, v in R['stages'].items():
        pr(f'    {k:36s} {_sts(v)}')
    pr(f'  frames started by: {R["frame_started_by"]}')
    pr('  display thread frame start -> 1st submit split: ' + '; '.join(f'{k} {_sts(v)}' for k, v in
                                                            R['start_to_submit_split'].items()))
    pr(f'  blocked time (start -> submit) by waker, total ms: {R["blocked_on_ms_total"]}; display thread on CPU '
       f'{R["display_oncpu_ms"]} ms; kernel calls after SwapEnd (ms): {R["after_swapend_kernel_calls_ms"]}')
    pr(f'  after SwapEnd the display thread runs {_sts(R["after_swapend_run_ms"])} before it first blocks; that block '
       f'- its frame\'s GPU done {_sts(R["after_swapend_block_minus_gpu_done_ms"])} (within 1 ms: '
       f'{R["after_swapend_block_within_1ms_of_gpu_done"]} of {R["after_swapend_frames"]})')
    pr(f'  frames with start -> submit > 20 ms: {len(long_)}; their kernel calls > 0.5 ms: {R["long_frame_calls"]}')
    for x in R['long_frames'][:10]:
        pr(f'    long: {x}')
    pr(f'  CA prepare / encode against the frame\'s GPU time (work proxy): {R["encode_by_gpu_ms"]}')
    pr(f'  GPU per frame (swap fence) {_sts(R["gpu_ms"])}; during swipes {_sts(R["swipe_gpu_ms"])}')
    pr(f'  GPU per frame (all display-thread submits, {_sts(R["submits_per_frame"])} per frame) '
       f'{_sts(R["gpu_all_submits_ms"])}; during swipes {_sts(R["swipe_gpu_all_submits_ms"])}; GPU busy during swipes '
       f'{R["swipe_gpu_busy_pct"]} %')
    R['_commits'] = commits
    R['_frames'] = frames
    return R


CAUSE_GROUPS = collections.OrderedDict([
    ('idle start', ()),     # late frames with the first app commit after > 200 ms idle, whatever their cause (cnt_idle)
    ('late commit phase', ('app_phase', 'app_cpu')),
    ('no new commit (app cadence)', ('app_rate', 'content')),
    ('encode too long (bb CPU)', ('bb_cpu', 'bb_busy', 'bb_post')),
    ('GPU', ('gpu_long', 'gpu_late')),
    ('swap/flip back-pressure', ('swapwait', 'gate', 'flip')),
    ('other', ('bb_skip', 'no_tick', 'other')),
])


def summary(a, T, label, basics, PR, CH, ipc_rows):
    """--summary-json: one test's numbers for the coordinator's dashboard"""
    S = {'label': label, 'trace': a.trace, 'app': a.app, 'span_ms': round(T.ms(T.end_abs), 1)}
    S.update(basics)
    if not basics.get('frames'):
        S['warning'] = 'no frames on screen in this trace (no SwapEnd / present / latch): nothing was rendered'
    if PR:
        S['period_ms'] = round(PR['Pms'], 4)
        S['panel_hz'] = round(1000 / PR['Pms'], 3)
        S['tick_after_edge_ms'] = round(PR['tick_lag'], 3)
        S['app_timer_period_ms'] = round(PR['app_period'], 4) if PR['app_period'] else None
        S['present_path'] = PR['path']
        iv = lambda c: {'1': c.get(1, 0), '2': c.get(2, 0), '3': c.get(3, 0), '4+': c.get(4, 0)}
        S['interval_vsyncs'] = iv(PR['ivs'])
        S['interval_vsyncs_swipe'] = iv(PR['ivs_sw'])
        fr = PR['frames']
        ivms = [(fr[i]['n'] - fr[i - 1]['n']) * PR['Pms'] for i in range(1, len(fr)) if fr[i]['n'] - fr[i - 1]['n'] <= 30]
        S['interval_ms'] = _st(ivms)
        S['gpu_ms_swipe'] = _st(PR['gpu_sw'])
        rc = {}
        for k in PR['CAUSES']:
            if PR['cnt'][k]:
                rc[k] = {'all': PR['cnt'][k], '2v': PR['by_iv'][2][k], '3v': PR['by_iv'][3][k],
                         '4+v': PR['by_iv'][4][k], 'swipe': PR['cnt_sw'][k]}
        S['root_causes'] = rc
        ci, cis = PR.get('cnt_idle', {}), PR.get('cnt_idle_sw', {})
        S['root_cause_groups'] = {g: ({'all': sum(ci.values()), 'swipe': sum(cis.values())} if g == 'idle start' else
                                      {'all': sum(PR['cnt'][k] - ci.get(k, 0) for k in ks),
                                       'swipe': sum(PR['cnt_sw'][k] - cis.get(k, 0) for k in ks)})
                                  for g, ks in CAUSE_GROUPS.items()}
        S['idle_start_by_cause'] = dict(ci)
        S['swipe_fps'] = PR.get('swipe_fps')
        S['late_intervals_swipe'] = sum(v for k, v in PR['ivs_sw'].items() if k >= 2)
        S['app_cadence_by_waker'] = dict(PR['rate_by'])
        S['app_cadence_by_waker_swipe'] = dict(PR['rate_by_sw'])
    if CH:
        S['chain'] = {k: v for k, v in CH.items() if not k.startswith('_')}
    if ipc_rows:
        S['ipc_top'] = ipc_rows[:15]
    return S


def write_json(a, T, threads, slices, calls, sw, fences, bb, app, sb, wakes, tname, gpu_abs, imsgs=(), CH=None):
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
    # mach messages with their msgh_id on the receiving thread (instant: id, name, sender, size, latency)
    nmsg = 0
    for m in imsgs:
        if m[8] is None or m[9] not in keep:
            continue
        if not (m[5] in (bb | app | sb) or m[6] in (bb | app | sb)):
            continue
        v = threads.get(m[9], [-1, '?', ''])
        pid = v[0] if v[0] >= 0 else 99999
        ev.append({'ph': 'i', 's': 't', 'name': f'msg {m[4]}', 'pid': pid, 'tid': m[9], 'ts': us(m[8]),
                   'args': {'id': m[4], 'what': msg_name(m[4]), 'from': tname(m[1]), 'bytes': m[7],
                            'latency_us': round(us(m[8]) - us(m[0]), 1)}})
        nmsg += 1
    if CH:
        # per-frame critical path: tick -> display wake -> CA prepare -> encode -> GPU -> present -> visible edge, on
        # two alternating tracks (frames overlap); the app commits and how long each waited for a frame
        for nm, i in (('frame chain A', 8), ('frame chain B', 9), ('app commits A', 10), ('app commits B', 11)):
            ev.append({'ph': 'M', 'name': 'thread_name', 'pid': VP, 'tid': i, 'args': {'name': nm}})
        for i, fr in enumerate(CH['_frames']):
            tid = 8 + (i & 1)
            t_end = max(x for x in (fr.get('E'), fr.get('F'), fr.get('G'), fr.get('SE')) if x is not None)
            t0 = min(x for x in (fr.get('V'), fr['W'], fr['start']) if x is not None)
            ev.append({'ph': 'X', 'name': f'frame swap {fr["swap"]} ({fr["gpu"] or 0:.1f} ms GPU)', 'pid': VP,
                       'tid': tid, 'ts': us(t0), 'dur': max(0.001, us(t_end) - us(t0)),
                       'args': {'gpu_ms': fr['gpu'], 'gpu_all_submits_ms': fr['gpu_all'], 'started_by': fr['startby'],
                                'woken_by': fr['Wby'], 'split_ms': fr['split'],
                                'blocked_on_ms': fr['blk'], 'big_calls': fr['bigcalls']}})
            gpu_end = max(x for x in (fr.get('G'), fr.get('SE'), fr.get('S0')) if x is not None)
            segs = [('tick -> wake', fr.get('V'), fr['W']) if fr['start'] >= fr['W'] else ('after previous frame', t0, fr['start']),
                    ('CA prepare', fr['start'], fr['B']),
                    ('encode', fr['B'], fr.get('S0')), ('GPU / SwapEnd', fr.get('S0'), gpu_end),
                    ('present', gpu_end, fr.get('F')), ('wait for edge', fr.get('F'), fr.get('E'))]
            prev = t0
            for nm, s0, s1 in segs:
                if s0 is None or s1 is None:
                    continue
                s0 = max(s0, prev)
                s1 = min(s1, t_end)
                if s1 > s0:
                    ev.append({'ph': 'X', 'name': nm, 'pid': VP, 'tid': tid, 'ts': us(s0), 'dur': us(s1) - us(s0)})
                    prev = s1
        for i, c in enumerate(CH['_commits']):
            tid = 10 + (i & 1)
            ev.append({'ph': 'X', 'name': f'commit {c["n"]} msgs {c["bytes"]} B ({c["why"]})', 'pid': VP, 'tid': tid,
                       'ts': us(c['s0']), 'dur': max(0.001, us(c['done']) - us(c['s0'])),
                       'args': {'phase_after_tick_ms': c['phase'], 'receiver': tname(c['rtid'])}})
            fr = c.get('frame')
            if fr is not None and fr['W'] > c['done']:
                ev.append({'ph': 'X', 'name': f'wait for frame (+{c.get("late_ticks", 0)} ticks)', 'pid': VP,
                           'tid': tid, 'ts': us(c['done']), 'dur': us(fr['W']) - us(c['done'])})
    with open(a.json, 'w') as f:
        json.dump({'traceEvents': ev, 'displayTimeUnit': 'ms'}, f)
    print(f'{a.json}: {len(ev)} trace events, {nmsg} message annotations (open in ui.perfetto.dev)')


if __name__ == '__main__':
    main()
