#!/usr/bin/env python3
"""L9 fence-wait cost from a sweettrace (.swtr/.red): kernel GPU_WAIT calls per thread (count, timeouts, on-CPU inside,
wakeups inside), GPU end stamp -> wait END and -> SCAN_FLIP latency, 0999 GPU_IRQ counts and GPU end -> IRQ.
  l9-fence-wait.py TRACE [path/to/sweet-trace.py]   (default tools-claude/sweet-trace.py)"""
import sys, collections, bisect, importlib.util, statistics as stt
spec = importlib.util.spec_from_file_location('st', sys.argv[2] if len(sys.argv) > 2 else 'tools-claude/sweet-trace.py')
st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
T = st.Trace(sys.argv[1])
toms = lambda d: d * T.numer / T.denom / 1e6
th = T.threads
def tn(t):
    x = th.get(t); return f'{x[1]}[{x[0]}]/{x[2] or t}' if x else str(t)
SWB = st.SW_BASE
ev = collections.Counter()
stack = collections.defaultdict(list)
waits = []   # (s, e, tid, fence, timeout, res, lastdone)
accel = []   # (s,e,tid,method, ret)
cal = []; done = []; irqs = []
sched_tids = collections.Counter()
mk = collections.defaultdict(list)  # tid -> makerunnable ts
runs = collections.defaultdict(list)
cur = {}; rs = {}
for e in T.events:
    ts,a1,a2,a3,a4,tid,dbg,cpu,_ = e
    cid = dbg & ~3; fn = dbg & 3
    if cid in (st.MACH_SCHED, st.MACH_STACK_HANDOFF):
        old = cur.get(cpu); new = a2
        if old is not None and old != new and old in rs:
            runs[old].append((rs.pop(old), ts))
        if old != new: rs[new] = ts
        cur[cpu] = new
    elif cid == st.MACH_MAKERUNNABLE:
        mk[a1].append(ts)
    elif (dbg & 0xffff0000) == SWB:
        c = (dbg >> 2) & 0x3fff
        ev[(c,fn)] += 1
        if c == 0x13 and a1: cal.append((a1, (a2+a3)/2))
        if c == 0x11: done.append((a1, a2, a3, a4))
        if c == 0x16: irqs.append((ts, a1, a2))
        if c in (0x12, 0x15):
            if fn == 1: stack[(tid,c)].append((ts,a1,a2,a3,a4))
            elif fn == 2 and stack[(tid,c)]:
                s = stack[(tid,c)].pop()
                if c == 0x12: waits.append((s[0], ts, tid, s[1], s[2], a2, a3))
                else: accel.append((s[0], ts, tid, s[1], a2))
print('trace ms', round(toms(T.end_abs - T.start_abs)), 'sw events', {f'{k[0]:#x}/{k[1]}': v for k, v in sorted(ev.items())})
# GPU clock
cal.sort()
tpa = (cal[-1][0]-cal[0][0])/(cal[-1][1]-cal[0][1])
g0,t0 = cal[0]
gabs = lambda g: t0 + (g-g0)/tpa
fend = {}
for f,s,e,pid in done: fend[f] = gabs(e)
# accel methods
am = collections.Counter(); amt = collections.Counter(); amto = collections.Counter()
for s,e,tid,m,r in accel:
    k=(tn(tid), st.ACCEL_NAMES.get(m, m)); am[k]+=1; amt[k]+=e-s
    if r: amto[k]+=1
print('\naccel methods (thread, method): calls, total ms, nonzero ret')
for k,v in am.most_common(15): print(f'  {k}: {v}, {toms(amt[k]):.1f} ms, {amto[k]}')
# waits
byt = collections.defaultdict(list)
for w in waits: byt[w[2]].append(w)
run_starts = {t: [a for a, _ in r] for t, r in runs.items()}
def oncpu(tid, s, e):
    tot = 0
    r = runs.get(tid, [])
    i = max(0, bisect.bisect_right(run_starts.get(tid, []), s) - 1)
    while i < len(r) and r[i][0] < e:
        a, b = r[i]
        if b > s: tot += min(b, e) - max(a, s)
        i += 1
    return tot
dur = toms(T.end_abs - T.start_abs)
print('\nGPU_WAIT (kernel fence waits that were not done at entry) per thread:')
for tid, ws in sorted(byt.items(), key=lambda x: -len(x[1])):
    d = [toms(e-s) for s,e,*_ in ws]; to = sum(1 for w in ws if w[5])
    cpu = sum(oncpu(tid, w[0], w[1]) for w in ws)
    nmk = sum(bisect.bisect_left(mk[tid], w[1]) - bisect.bisect_right(mk[tid], w[0]) for w in ws)
    lat = []
    for s,e,_,f,tmo,res,last in ws:
        if res == 0 and f in fend: lat.append((toms(e - fend[f]), f, last))
    lv = sorted(x[0] for x in lat)
    q = lambda p: lv[min(len(lv)-1, int(p*len(lv)))] if lv else None
    print(f'  {tn(tid)}: {len(ws)} waits ({len(ws)/dur*1000:.0f}/s), timeouts {to}, wall ms total {sum(d):.0f} median {stt.median(d):.2f} max {max(d):.2f}; '
          f'on-CPU in waits {toms(cpu):.1f} ms ({toms(cpu)/dur*1000:.1f} ms/s); wakeups inside waits {nmk} ({nmk/max(1,len(ws)):.1f}/wait)')
    if lv: print(f'     GPU end stamp -> wait END: n={len(lv)} min {lv[0]:.3f} p10 {q(.1):.3f} median {q(.5):.3f} p90 {q(.9):.3f} max {lv[-1]:.3f} ms; exact-fence (last==fence) {sum(1 for x in lat if x[2]==x[1])}')
# ---- GPU end -> SCAN_FLIP, swap fence mapping ----
swapfence = {}   # swap id -> fence (SWAP START a2)
flips = []; latches = []; vs = []
for e in T.events:
    ts,a1,a2,a3,a4,tid,dbg,cpu,_ = e
    if (dbg & 0xffff0000) != SWB: continue
    c = (dbg >> 2) & 0x3fff; fn = dbg & 3
    if c == 0x05 and fn == 1: swapfence[a1] = a2
    if c == 0x0a: flips.append((ts, a1, a2, a3, a4, tid))
    if c == 0x0b: latches.append((ts, a1, a2, a3, a4))
    if c == 0x01: vs.append((ts, a4))
lat = []; slack = []
fl_tids = collections.Counter()
for ts, sw_, seq, d, ff, tid in flips:
    fl_tids[tn(tid)] += 1
    f = swapfence.get(sw_)
    if f and f in fend:
        lat.append(toms(ts - fend[f]))
lat.sort()
if lat:
    q = lambda p: lat[min(len(lat)-1, int(p*len(lat)))]
    print(f'\nGPU end stamp -> SCAN_FLIP: n={len(lat)} min {lat[0]:.3f} p10 {q(.1):.3f} median {q(.5):.3f} p90 {q(.9):.3f} max {lat[-1]:.3f} ms; mean {sum(lat)/len(lat):.3f}; flip threads {dict(fl_tids)}')
    import collections as C
    h = C.Counter(min(12, int(x*4)) for x in lat)
    print('  histogram (0.25 ms bins):', dict(sorted(h.items())))
# edges: VSYNC ticks (a4 = INTF1 frame counter); missed-edge estimate
vts = [v[0] for v in vs]
miss = 0; n = 0
for ts, sw_, seq, d, ff, tid in flips:
    f = swapfence.get(sw_)
    if not (f and f in fend): continue
    g = fend[f]; n += 1
    i = bisect.bisect_right(vts, g)
    if i < len(vts) and vts[i] < ts: miss += 1
print(f'flips where a vsync tick fell between GPU end and the flip: {miss}/{n}')
# CPU of queue-wait per on-screen frame
qw = [t for t in byt if 'queue-wait' in tn(t)]
for t in qw:
    cpu = sum(oncpu(t, w[0], w[1]) for w in byt[t])
    allcpu = sum(b-a for a,b in runs.get(t, []))
    print(f'{tn(t)}: on-CPU in kernel waits {toms(cpu):.0f} ms, thread total on-CPU {toms(allcpu):.0f} ms, per flip {toms(cpu)/max(1,len(flips)):.2f} ms; sched runs {len(runs.get(t,[]))}')
# which CPUs the queue-wait thread ran on vs display thread overlap: count preemptions of display.primary by queue-wait

# ---- 0999 GPU interrupts ----
if irqs:
    lat = sorted(toms(ts - fend[f]) for ts, st_, f in irqs if f in fend)
    q = lambda p: lat[min(len(lat)-1, int(p*len(lat)))]
    print(f'GPU_IRQ: {len(irqs)} ({len(irqs)/dur*1000:.0f}/s); GPU end stamp -> IRQ (its last done fence): n={len(lat)} '
          f'median {q(.5):.3f} p90 {q(.9):.3f} max {lat[-1]:.3f} ms' if lat else f'GPU_IRQ: {len(irqs)}')
else:
    print('GPU_IRQ: none (0999 off, or an older kernel)')
