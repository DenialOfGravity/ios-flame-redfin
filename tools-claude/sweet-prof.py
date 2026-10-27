#!/usr/bin/env python3
"""sweet-prof.py: profiles from the kernel sampler (xnu 0991, p prof) on redfin.

  sweet-prof.py BIN need [--imp]              phone commands that symbolise the shared-cache addresses not yet in the
                                              cache (a2s; --imp: imgdump imp for the ones a2s left <redacted>)
  sweet-prof.py BIN report [options]          flat (self) and inclusive profiles, per thread, phases, off-CPU
      --sym FILE...      a2s / imgdump-imp output files (e.g. agent/outbox/*.out) to add to the symbol cache
      --macho-dir DIR    local unstripped Mach-Os for the images outside the shared cache (matched by file name;
                         e.g. builds/metal2/<ref> for SweetMetal2 + libvulkan_freedreno)
      --kernel FILE      kernel Mach-O (builds/xnu/<ref>/kernel.development.sweet.gz) for kernel-mode samples
      --thread TEXT      only threads whose name (or tid) contains TEXT
      --phase NAME       only samples between mark NAME and the next mark
      --top N            rows per table (default 25)
      --folded OUT       folded stacks (thread;root;...;leaf count) for flamegraph.pl / speedscope; off-CPU samples
                         go to OUT with .wait appended
BIN: the buffer read with the agent's  files read /dev/pmem PA BYTES /mnt/c/ClaudeProjects/iOS_Pixel5/logs/prof.bin
(PA and BYTES from the "SWEET PROF: done" klog line). Symbol cache: logs/prof-symcache.tsv (unslid shared-cache
addresses, valid across boots of the same iOS build)."""
import bisect, collections, gzip, os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(os.path.dirname(HERE), 'logs', 'prof-symcache.tsv')
UMASK = (1 << 40) - 1           # strips PAC bits (arm64e) and tags
KIND = {1: 'user', 2: 'kernel', 3: 'mark', 4: 'offcpu'}


def load(path):
    d = open(path, 'rb').read()
    if d[:7] != b'SWPROF1':
        sys.exit('%s: no SWPROF1 header (wrong PA, or the run is not done yet)' % path)
    f = struct.unpack_from('<8sIIQQQIIIIQQQQQIIIIIIIIIIII32s', d, 0)
    keys = ('magic rec0 text_size used start_abs end_abs hz depth wait_hz pid slide sr_base sr_size mh kslide ticks '
            'samples ksamples wsamples dropped xbusy xfail marks tb_num tb_den ncpu overruns name').split()
    h = dict(zip(keys, f))
    h['name'] = h['name'].split(b'\0')[0].decode(errors='replace')
    text = d[256:256 + h['text_size']].decode(errors='replace')
    threads, images = {}, []
    for l in text.splitlines():
        p = l.split(' ', 2)
        if p[0] == 'T' and len(p) >= 2:
            threads[int(p[1])] = p[2] if len(p) > 2 and p[2] else 'tid%s' % p[1]
        elif p[0] == 'I' and len(p) == 3:
            images.append((int(p[1], 16), p[2]))
    recs, off, end = [], h['rec0'], h['rec0'] + h['used']
    end = min(end, len(d))
    while off + 32 <= end:
        abs_, tid, kind, cpu, n, flags, aux, kpc = struct.unpack_from('<QQBBBBIQ', d, off)
        if kind not in KIND or off + 32 + 8 * n > end:
            break
        w = struct.unpack_from('<%dQ' % n, d, off + 32)
        recs.append((abs_, tid, kind, cpu, aux, kpc, w))
        off += 32 + 8 * n
    return h, threads, images, recs


def macho_syms(path):
    """(text vmaddr, sorted [(addr, name)]) from LC_SYMTAB of a thin or fat arm64 Mach-O."""
    d = open(path, 'rb').read()
    if d[:2] == b'\x1f\x8b':
        d = gzip.decompress(d)
    base = 0
    if struct.unpack_from('>I', d, 0)[0] == 0xcafebabe:
        for i in range(struct.unpack_from('>I', d, 4)[0]):
            ct, _, o, _, _ = struct.unpack_from('>IIIII', d, 8 + 20 * i)
            if ct == 0x0100000c:
                base = o
                break
    if struct.unpack_from('<I', d, base)[0] != 0xfeedfacf:
        return None
    ncmds = struct.unpack_from('<I', d, base + 16)[0]
    off, text, symtab = base + 32, 0, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == 0x19 and d[off + 8:off + 24].rstrip(b'\0') == b'__TEXT':
            text = struct.unpack_from('<Q', d, off + 24)[0]
        elif cmd == 0x2:
            symtab = struct.unpack_from('<IIII', d, off + 8)
        off += size
    syms = []
    if symtab:
        so, ns, st, _ = symtab
        for i in range(ns):
            strx, typ, sect, _, val = struct.unpack_from('<IBBHQ', d, base + so + 16 * i)
            if typ & 0xe0 or (typ & 0x0e) != 0x0e or not val:
                continue
            e = d.find(b'\0', base + st + strx)
            syms.append((val, d[base + st + strx:e].decode(errors='replace')))
    syms.sort()
    return text, syms


class Symbols:
    def __init__(self, h, images, args):
        self.h, self.cache, self.memo = h, {}, {}
        if os.path.exists(CACHE):
            for l in open(CACHE, errors='replace'):
                p = l.rstrip('\n').split('\t')
                if len(p) == 2:
                    self.cache[int(p[0], 16)] = p[1]
        self.dirty = False
        for f in args.get('sym', []):
            self.ingest(f)
        self.local = []         # (start, end, name, text vmaddr, syms)
        mdir = args.get('macho_dir')
        if mdir:
            files = {}
            for root, _, fs in os.walk(mdir):
                for fn in fs:
                    files.setdefault(fn, os.path.join(root, fn))
            for i, (a, path) in enumerate(sorted(images)):
                bn = os.path.basename(path)
                if bn in files:
                    m = macho_syms(files[bn])
                    if m:
                        nxt = sorted(images)[i + 1][0] if i + 1 < len(images) else a + (256 << 20)
                        self.local.append((a, nxt, bn, m[0], m[1]))
        self.images = sorted(images)
        self.kern = None
        if args.get('kernel'):
            m = macho_syms(args['kernel'])
            if m:
                self.kern = m[1]

    def ingest(self, path):
        slide = self.h['slide']
        for l in open(path, errors='replace'):
            m = re.match(r'(0x[0-9a-f]+) (\S+) (.+)$', l.strip())       # a2s: SLID IMAGE SYM+0xOFF
            if m and m[3] != '?':
                self.cache[int(m[1], 16) - slide] = '%s`%s' % (m[2], m[3])
                self.dirty = True
                continue
            m = re.match(r'(0x[0-9a-f]+): ([-+]\[.+\]\+0x[0-9a-f]+) \((.+)\)$', l.strip())    # imgdump imp: UNSLID
            if m:
                self.cache[int(m[1], 16)] = '%s`%s' % (os.path.basename(m[3]), m[2])
                self.dirty = True

    def save(self):
        if self.dirty:
            os.makedirs(os.path.dirname(CACHE), exist_ok=True)
            with open(CACHE + '.tmp', 'w') as f:
                for a in sorted(self.cache):
                    f.write('%x\t%s\n' % (a, self.cache[a]))
            os.replace(CACHE + '.tmp', CACHE)

    def in_cache_region(self, a):
        return self.h['sr_base'] <= a < self.h['sr_base'] + self.h['sr_size']

    def func(self, a):
        """function key for an address: IMAGE`SYMBOL (offsets dropped)."""
        if a in self.memo:
            return self.memo[a]
        r = self._func(a)
        self.memo[a] = r
        return r

    def _func(self, a):
        if self.in_cache_region(a):
            s = self.cache.get(a - self.h['slide'])
            if s is None:
                return '?cache 0x%x' % (a - self.h['slide'])
            m = re.match(r'(.*)\+0x([0-9a-f]+)$', s)
            if not m:
                return s
            name, off = m[1], int(m[2], 16)
            if name.endswith('`<redacted>'):
                return '%s 0x%x' % (name, a - self.h['slide'] - off)
            return name
        for lo, hi, bn, text, syms in self.local:
            if lo <= a < hi:
                v = a - lo + text
                i = bisect.bisect_right(syms, (v, '￿')) - 1
                return '%s`%s' % (bn, syms[i][1]) if i >= 0 else '%s+0x%x' % (bn, a - lo)
        i = bisect.bisect_right(self.images, (a, '￿')) - 1
        if i >= 0 and a - self.images[i][0] < (256 << 20):
            return '%s+0x%x' % (os.path.basename(self.images[i][1]), a - self.images[i][0])
        return '?0x%x' % a

    def kfunc(self, kpc):
        if not kpc:
            return '[kernel]'
        if not self.kern:
            return '[kernel]'
        v = kpc - self.h['kslide']
        i = bisect.bisect_right(self.kern, (v, '￿')) - 1
        return '[k] %s' % self.kern[i][1] if i >= 0 else '[kernel]'


def stack(rec, sy):
    """frames leaf first, as function keys; lr only when it is a frame the fp chain misses (leaf functions)."""
    _, tid, kind, cpu, aux, kpc, w = rec
    pc, lr = w[0] & UMASK, w[1] & UMASK
    rets = [x & UMASK for x in w[2:]]
    out = [sy.func(pc)]
    if lr and (not rets or lr != rets[0]):
        fl = sy.func(lr - 4)
        if fl != out[0] and (not rets or fl != sy.func(rets[0] - 4)):
            out.append(fl)
    out += [sy.func(r - 4) for r in rets if r]
    if kind == 2:
        out.insert(0, sy.kfunc(kpc))
    return out


def addrs_needed(h, recs, sy):
    need = set()
    for r in recs:
        if r[2] in (1, 2, 4):
            w = r[6]
            cand = [w[0] & UMASK] + [(x & UMASK) - 4 for x in w[1:] if x]
            for a in cand:
                if sy.in_cache_region(a) and (a - h['slide']) not in sy.cache:
                    need.add(a)
    return sorted(need)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, cmd, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    args, i = {}, 0
    while i < len(rest):
        k = rest[i]
        if k == '--sym':
            args['sym'] = []
            while i + 1 < len(rest) and not rest[i + 1].startswith('--'):
                args['sym'].append(rest[i + 1])
                i += 1
        elif k == '--imp':
            args['imp'] = True
        elif k in ('--macho-dir', '--kernel', '--thread', '--phase', '--top', '--folded'):
            args[k[2:].replace('-', '_')] = rest[i + 1]
            i += 1
        else:
            sys.exit('unknown option ' + k)
        i += 1
    h, threads, images, recs = load(path)
    sy = Symbols(h, images, args)
    tbns = h['tb_num'] / h['tb_den'] if h['tb_den'] else 1 / 19.2
    if cmd == 'need':
        if args.get('imp'):
            red = sorted({a for a, s in sy.cache.items() if '`<redacted>' in s})
            todo = ['0x%x' % (a - int(re.search(r'\+0x([0-9a-f]+)$', sy.cache[a])[1], 16)) for a in red] if red else []
            todo = sorted(set(todo))
            for j in range(0, len(todo), 300):
                print('phone /var/local/bin/imgdump imp ' + ' '.join(todo[j:j + 300]))
            print('# %d redacted functions; then: report --sym <those outbox files>' % len(todo), file=sys.stderr)
        else:
            need = addrs_needed(h, recs, sy)
            for j in range(0, len(need), 300):
                print('phone /var/local/bin/a2s ' + ' '.join('0x%x' % a for a in need[j:j + 300]))
            print('# %d shared-cache addresses to look up (%d cached); send each line as an agent request, then: '
                  'report --sym agent/outbox/<those>.out' % (len(need), len(sy.cache)), file=sys.stderr)
        sy.save()
        return
    if cmd != 'report':
        sys.exit(__doc__)
    top = int(args.get('top', 25))
    tname = lambda t: threads.get(t, 'tid%d' % t)
    # phases from marks
    marks = sorted((r[0], b''.join(struct.pack('<Q', x) for x in r[6]).split(b'\0')[0].decode(errors='replace'))
                   for r in recs if r[2] == 3)
    def phase_of(t):
        i = bisect.bisect_right(marks, (t, '￿')) - 1
        return marks[i][1] if i >= 0 else '(start)'
    sel = [r for r in recs if r[2] != 3]
    if args.get('thread'):
        tt = args['thread']
        sel = [r for r in sel if tt in tname(r[1]) or tt == str(r[1])]
    if args.get('phase'):
        sel = [r for r in sel if phase_of(r[0]).split()[0] == args['phase'] or phase_of(r[0]) == args['phase']]
    dur = (h['end_abs'] - h['start_abs']) * tbns / 1e9
    print('%s[%d]: %.2f s at %d Hz (depth %d, off-CPU %d Hz): %d user + %d kernel + %d off-CPU samples, %d marks; '
          'ticks %d (%d late), dropped %d, xcall busy %d fail %d' % (h['name'], h['pid'], dur, h['hz'], h['depth'],
          h['wait_hz'], h['samples'], h['ksamples'], h['wsamples'], h['marks'], h['ticks'], h['overruns'],
          h['dropped'], h['xbusy'], h['xfail']))
    if h['dropped']:
        print('  WARNING: the buffer filled; later samples are missing (lower HZ, DEPTH or SECS)')
    on = [r for r in sel if r[2] in (1, 2)]
    off = [r for r in sel if r[2] == 4]
    # per thread
    per = collections.Counter(r[1] for r in on)
    perk = collections.Counter(r[1] for r in on if r[2] == 2)
    print('\nthreads (on-CPU samples; CPU ms/s = samples / HZ / s * 1000):')
    for t, n in per.most_common(top):
        print('  %6d  %5.1f%%  %6.1f ms/s  kernel %4.1f%%  %s' % (n, 100 * n / len(on), n / h['hz'] / max(dur, 1e-9)
              * 1000, 100 * perk[t] / n, tname(t)))
    if marks:
        print('\nphases (on-CPU samples per mark):')
        ph = collections.Counter(phase_of(r[0]) for r in on)
        for name in dict.fromkeys(m[1] for m in marks):
            print('  %6d  %s' % (ph[name], name))
    stacks = [(r, stack(r, sy)) for r in on]
    selfc, incl = collections.Counter(), collections.Counter()
    for r, s in stacks:
        selfc[s[0]] += 1
        for f in set(s):
            incl[f] += 1
    n = max(len(on), 1)
    print('\nself (leaf) %d on-CPU samples:' % len(on))
    for f, c in selfc.most_common(top):
        print('  %6d  %5.1f%%  %s' % (c, 100 * c / n, f))
    print('\ninclusive:')
    for f, c in incl.most_common(top):
        print('  %6d  %5.1f%%  %s' % (c, 100 * c / n, f))
    if off:
        st = collections.Counter('wait' if r[4] & 1 else 'runnable' for r in off)
        print('\noff-CPU %d samples: %s' % (len(off), ', '.join('%s %d' % kv for kv in st.most_common())))
        ow = collections.Counter()
        for r in off:
            s = stack(r, sy)
            ow[(tname(r[1]), 'wait' if r[4] & 1 else 'runnable', ' < '.join(s[:3]))] += 1
        for (t, k, s), c in ow.most_common(top):
            print('  %6d  %-8s %-28s %s' % (c, k, t[:28], s))
    q = sum(1 for _, s in stacks if s[0].startswith('?cache'))
    if q:
        print('\n%d leaf frames have no shared-cache symbol yet: run "need" and send its phone lines' % q)
    if args.get('folded'):
        def fold(items, outp):
            c = collections.Counter()
            for r, s in items:
                c[';'.join([tname(r[1]).replace(';', ':')] + [x.replace(';', ':') for x in reversed(s)])] += 1
            with open(outp, 'w') as f:
                for k, v in c.most_common():
                    f.write('%s %d\n' % (k, v))
        fold(stacks, args['folded'])
        if off:
            fold([(r, stack(r, sy)) for r in off], args['folded'] + '.wait')
        print('\nfolded stacks -> %s' % args['folded'])
    sy.save()


if __name__ == '__main__':
    main()
