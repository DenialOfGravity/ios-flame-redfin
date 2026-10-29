#!/usr/bin/env python3
"""fps-parse.py KLOG RUN [TSV [key=value ...]]: one row from the lines between 'fpsbench-start RUN' and
'fpsbench-end RUN', per gesture phase ("SWEET PHASE: NAME" from p phase on 0991 kernels, else the
"p phase NAME" command lines), then the median and spread of all TSV rows with the same label.
fps.SCOPE = (panel-buffer frames shown + direct-scanout frames latched) / the phases' wall time.
       fps-parse.py --summary LABEL TSV     just the median/spread of LABEL's rows
Measured phases (the "all" columns): pages, settings, cc.
hitch35_active / worst_active_ms (appended last): backboardd's per-5s 'native-metal: T worst' lines list the worst frame
intervals with the idle 'gap' before each; a frame after an idle gap > 200 ms (first frame of a gesture) is not a hitch.
hitch35_active = % of swaps > 35 ms in the measured phases without those post-idle frames; worst_active_ms = the
largest listed interval in the measured phases whose gap is <= 200 ms.
sc1 (direct scanout, rk2a+): a phase with SCANOUT frames latched counts as direct. Its FB line has 'shown 0' (or a few
non-slot frames) with every swap in gt35, so the FB bucket/p50/p95 columns (%<=11.1ms %<=18ms p50 p95max
hitch35_active) are left EMPTY (n/a) when any measured phase was direct; fps = (FB shown + SCANOUT latched) / time.
Appended columns: scan_swap_latch_p50 (ms, latched-weighted median of the per-5s swap->latch means), scan_dropped,
chain (CA swap-chain depth min-max over the windows), fps_src (blit|scanout|mixed).
Finer frame-interval data in direct mode would need a kernel stat: latch-to-latch interval buckets (le11/le18/le26/
le35/gt35 and p50/p95 of the time between successive latched flips) in the SCANOUT 5s line, like the FB line's."""
import os, re, statistics, sys

MEASURED = ('pages', 'settings', 'cc')
# (TSV column, key=value argument) appended after 'phases' by redfin-fpsbench.sh v3
EXTRA = [('temp start', 'temp0'), ('temp wait s', 'twait'), ('set via', 'setvia'), ('pg1 tries pages', 'pg1_pages'),
         ('pg1 tries cc', 'pg1_cc'), ('chk pages', 'chk_pages'), ('chk settings', 'chk_settings'), ('chk cc', 'chk_cc'),
         ('klog src', 'ksrc')]
TS = re.compile(r'^\[\s*([\d.]+)\]')
IDLE_GAP_MS = 200.0
WORST = re.compile(r'([\d.]+)ms = prev\[[^\]]*\] gap (-?[\d.]+)')


def parse(klog, run):
    lines = open(klog, errors='replace').read().replace('\0', '').splitlines()
    st = [i for i, l in enumerate(lines) if 'fpsbench-start ' + run in l]
    en = [i for i, l in enumerate(lines) if 'fpsbench-end ' + run in l]
    if not st:
        sys.exit('no start marker for ' + run)
    seg = lines[st[-1]:(en[-1] + 1 if en and en[-1] > st[-1] else len(lines))]
    t = lambda l: float(TS.match(l)[1]) if TS.match(l) else None
    kern = any('SWEET PHASE: ' in l for l in seg)
    marks = []
    for l in seg:
        m = re.search(r'SWEET PHASE: (\S+)', l) if kern else re.search(r'bytes: p phase (\S+)', l)
        if m and t(l) is not None:
            marks.append((t(l), m[1]))
    t_end = t(seg[-1]) or (marks[-1][0] if marks else 0)
    if not marks:
        marks = [(t(seg[0]) or 0, 'all')]
    ph = {}
    for k, (t0, name) in enumerate(marks):
        t1 = marks[k + 1][0] if k + 1 < len(marks) else t_end
        p = ph.setdefault(name, dict(dur=0.0, shown=0, swaps=0, fbdrop=0, b=[0] * 5, p50=[], p95=[], latched=0,
                                      sframes=0, sdrop=0, s2l=[], chain=[], direct=0, gpu_ms=0.0, gsub=0, wins=0,
                                      postidle=0, postidle35=0, worst_active=None))
        p['dur'] += max(t1 - t0, 0.0)
    cur = None
    mi = 0
    for l in seg:
        tl = t(l)
        if kern:
            m = re.search(r'SWEET PHASE: (\S+)', l)
            if m:
                cur = m[1]
                continue
        else:
            # old kernel: a stats line covers the 5 s before it; attribute it to the phase of its midpoint
            if tl is None:
                continue
            mid = max(tl - 2.5, marks[0][0])
            cur = None
            for t0, name in marks:
                if t0 <= mid:
                    cur = name
        if cur is None or cur not in ph:
            continue
        p = ph[cur]
        m = re.search(r'SWEET FB: 5s: swaps (\d+) shown (\d+) dropped (\d+) \| le11 (\d+) le18 (\d+) le26 (\d+) '
                      r'le35 (\d+) gt35 (\d+) \| p50 ([\d.]+) p95 ([\d.]+)', l)
        if m:
            v = [int(x) for x in m.groups()[:8]]
            p['swaps'] += v[0]; p['shown'] += v[1]; p['fbdrop'] += v[2]
            p['b'] = [a + b for a, b in zip(p['b'], v[3:8])]
            if v[1]:
                p['p50'].append((float(m[9]), v[1])); p['p95'].append(float(m[10]))
            p['wins'] += 1
            continue
        m = re.search(r'SWEET SCANOUT: 5s: frames (\d+) flips (\d+) latched (\d+) dropped (\d+).*?swap->latch (\d+) us', l)
        if m:
            p['sframes'] += int(m[1]); p['latched'] += int(m[3]); p['sdrop'] += int(m[4])
            if int(m[3]):
                p['s2l'].append((int(m[5]), int(m[3])))
                p['direct'] += 1
            c = re.search(r'\| chain (\d+)-(\d+) \|', l)
            if c and int(m[1]):
                p['chain'] += [int(c[1]), int(c[2])]
            continue
        if 'native-metal: T worst' in l and ('MTL2[' not in l or 'backboardd]' in l):
            for tot, gap in WORST.findall(l.split('|', 1)[-1]):
                tot, gap = float(tot), float(gap)
                if gap > IDLE_GAP_MS:
                    p['postidle'] += 1
                    p['postidle35'] += tot > 35
                elif p['worst_active'] is None or tot > p['worst_active']:
                    p['worst_active'] = tot
            continue
        m = re.search(r'SWEET GPU: 5s: (\d+) submits.*?GPU busy (\d+) ms', l)
        if m:
            p['gsub'] += int(m[1]); p['gpu_ms'] += float(m[2])
    return ph, kern


NA = 'n/a'	# sc1: a column that does not apply to direct-scanout runs (written as an empty cell)


def wmedian(pairs):
    """median of (value, weight) pairs, in ms (values in us); None when empty"""
    pairs = sorted(pairs)
    n = sum(w for _, w in pairs)
    if not n:
        return None
    acc = 0
    for v, w in pairs:
        acc += w
        if 2 * acc >= n:
            return v / 1000
    return pairs[-1][0] / 1000


def wmean(pairs):
    n = sum(w for _, w in pairs)
    return sum(v * w for v, w in pairs) / n if n else 0


def row_for(ph, kern, run, meta):
    def agg(names):
        ps = [ph[n] for n in names if n in ph]
        dur = sum(p['dur'] for p in ps)
        fr = sum(p['shown'] + p['latched'] for p in ps)
        b = [sum(p['b'][i] for p in ps) for i in range(5)]
        nb = sum(b)
        gpu = sum(p['gpu_ms'] for p in ps)
        pi, pi35 = sum(p['postidle'] for p in ps), sum(p['postidle35'] for p in ps)
        wa = [p['worst_active'] for p in ps if p['worst_active'] is not None]
        out = [dict(dur=dur, fps=fr / dur if dur else 0, frames=fr, shown=sum(p['shown'] for p in ps),
                    latched=sum(p['latched'] for p in ps), drop=sum(p['fbdrop'] + p['sdrop'] for p in ps),
                    le11=100 * b[0] / nb if nb else None, le18=100 * (b[0] + b[1]) / nb if nb else None,
                    p50=wmean([x for p in ps for x in p['p50']]) if any(p['p50'] for p in ps) else None,
                    p95=max([x for p in ps for x in p['p95']]) if any(p['p95'] for p in ps) else None,
                    s2l=wmean([x for p in ps for x in p['s2l']]) / 1000 if any(p['s2l'] for p in ps) else None, gpu=100 * gpu / 1000 / dur if dur else 0,
                    gpf=gpu / fr if fr else 0,
                    h35a=100 * max(b[4] - pi35, 0) / (nb - pi) if nb - pi > 0 else None, wact=max(wa) if wa else None,
                    direct=any(p['direct'] for p in ps), sdrop=sum(p['sdrop'] for p in ps),
                    s2l50=wmedian([x for p in ps for x in p['s2l']]),
                    chain='%d-%d' % (min(ch), max(ch)) if (ch := [c for p in ps for c in p['chain']]) else '-')]
        r = out[-1]
        r['src'] = ('scanout' if r['shown'] <= r['latched'] // 20 else 'mixed') if r['direct'] else 'blit'
        if r['direct']:	# sc1: FB buckets/p50/p95 describe the unused panel-buffer path: n/a
            for k in ('le11', 'le18', 'p50', 'p95', 'h35a'):
                r[k] = NA
        return r
    a = agg(MEASURED if any(n in ph for n in MEASURED) else list(ph))
    f = lambda v, d=1: '' if v is NA else ('-' if v is None else ('%.' + str(d) + 'f') % v)
    hdr = ['label', 'fps all', 'fps pages', 'fps settings', 'fps cc', 'frames', 'fb shown', 'scan latched', 'dropped',
           '%<=11.1ms', '%<=18ms', 'p50 ms', 'p95max ms', 'swap->latch ms', 'GPU busy%', 'GPU ms/frame',
           'bbd cpu%', 'sb cpu%', 'disp start', 'disp end', 'settings', 'phases']
    fp = lambda n: f(agg([n])['fps']) if n in ph else '-'
    row = [run, f(a['fps']), fp('pages'), fp('settings'), fp('cc'),
           str(a['frames']), str(a['shown']), str(a['latched']), str(a['drop']), f(a['le11']), f(a['le18']), f(a['p50']),
           f(a['p95']), f(a['s2l']), f(a['gpu']), f(a['gpf'], 2), meta.get('bbd_cpu', '-'), meta.get('sb_cpu', '-'),
           meta.get('disp0', '-'), meta.get('disp1', '-'), meta.get('settings', '-'), 'kernel' if kern else 'time']
    # v3 columns (appended; older rows simply end at 'phases')
    hdr += [h for h, _ in EXTRA]
    row += [meta.get(k, '-') or '-' for _, k in EXTRA]
    # hitch columns without post-idle frames (appended after the v3 columns)
    hdr += ['hitch35_active', 'worst_active_ms']
    row += [f(a['h35a']), f(a['wact'])]
    # sc1: direct-scanout columns (appended after the hitch columns)
    hdr += ['scan_swap_latch_p50', 'scan_dropped', 'chain', 'fps_src']
    row += [f(a['s2l50'], 2), str(a['sdrop']), a['chain'], a['src']]
    print('phase        s     fps  frames shown latched drop   p50   p95max  GPU%  GPU ms/fr  h35act  worstact  src     s2l50 chain')
    for n, p in ph.items():
        q = agg([n])
        print('%-10s %5.1f %6.1f %6d %5d %6d %5d %6s %7s %5.1f %6.2f %7s %9s' % (n, q['dur'], q['fps'], q['frames'],
              q['shown'], q['latched'], q['drop'], f(q['p50']), f(q['p95']), q['gpu'], q['gpf'], f(q['h35a']),
              f(q['wact'])) + '  %-7s %5s %s' % (q['src'], f(q['s2l50'], 2), q['chain']))
    return hdr, row


def summary(label, tsv):
    if not os.path.exists(tsv):
        return
    rows = [l.rstrip('\n').split('\t') for l in open(tsv)]
    hdr = None
    sel = []
    for r in rows:
        if r and r[0] == 'label':
            hdr = r
            continue
        if hdr and re.fullmatch(re.escape(label) + r'-\d{6}', r[0]):
            sel.append(dict(zip(hdr, r)))
    if not sel:
        return
    print('\n%s: %d runs (settings ok %d, display on at start %d)' % (label, len(sel),
          sum(r.get('settings') == 'ok' for r in sel), sum(r.get('disp start') in ('on', 'woken') for r in sel)))
    for k in ('fps all', 'fps pages', 'fps settings', 'fps cc', 'p50 ms', 'p95max ms', 'GPU busy%', 'GPU ms/frame',
              'bbd cpu%', 'hitch35_active', 'worst_active_ms', 'scan_swap_latch_p50', 'scan_dropped'):
        v = []
        for r in sel:
            try:
                v.append(float(r.get(k, '')))
            except ValueError:
                pass
        if v:
            med = statistics.median(v)
            print('  %-13s median %7.2f  min %7.2f  max %7.2f  spread %5.1f%%' % (k, med, min(v), max(v),
                  100 * (max(v) - min(v)) / med if med else 0))


def main():
    if sys.argv[1] == '--summary':
        summary(sys.argv[2], sys.argv[3])
        return
    klog, run = sys.argv[1], sys.argv[2]
    tsv = sys.argv[3] if len(sys.argv) > 3 else None
    meta = dict(a.split('=', 1) for a in sys.argv[4:] if '=' in a)
    ph, kern = parse(klog, run)
    hdr, row = row_for(ph, kern, run, meta)
    print('\t'.join(hdr)); print('\t'.join(row))
    if tsv:
        last = None
        if os.path.exists(tsv):
            for l in open(tsv):
                if l.startswith('label\t'):
                    last = l.rstrip('\n')
        with open(tsv, 'a') as f:
            if last != '\t'.join(hdr):	# new file or new column set: a header line (summary() takes the latest one)
                f.write('\t'.join(hdr) + '\n')
            f.write('\t'.join(row) + '\n')
        summary(re.sub(r'-\d{6}$', '', run), tsv)


if __name__ == '__main__':
    main()
