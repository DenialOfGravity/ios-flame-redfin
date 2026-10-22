#!/usr/bin/env python3
"""flame-profile.py PROC SAMPLES [--swipes N]: sample a phone process's thread stacks (phone/tools pstack) while
swiping the home screen, then print the hottest frames per thread (leaf and inclusive).
Symbols: SweetMetal2 and Turnip with atos (bases from /var/local/mtl2.log "images:"), the shared cache with ipsw."""
import collections, os, re, subprocess, sys, threading, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
proc, samples = sys.argv[1], int(sys.argv[2])
swipes = int(sys.argv[sys.argv.index('--swipes') + 1]) if '--swipes' in sys.argv else 10
ssh = lambda c: subprocess.run([ROOT + '/tools/flame-ssh', c], capture_output=True, text=True).stdout
pid = ssh('psx %s' % proc).split()[0]
img = [l for l in ssh('grep "images:" /var/local/mtl2.log').split('\n') if '[%s ' % pid in l][-1]
sm2_base, tu_base = (int(x, 16) for x in re.findall(r'(0x[0-9a-f]+)', img)[:2])
def swiper():
    for _ in range(swipes):
        for a in ('900 1200 150 1200 250', '150 1200 900 1200 250'):
            subprocess.run(['python3', ROOT + '/tools/flame-cmd.py', 'swipe'] + a.split(), capture_output=True)
t = threading.Thread(target=swiper); t.start()
out = ssh('i=0; while [ $i -lt %d ]; do pstack %s; i=$((i+1)); done' % (samples, pid))
t.join()
open(ROOT + '/work/m2v/profile-raw.txt', 'w').write(out)
slide = int(re.search(r'slide 0x([0-9a-f]+)', out).group(1), 16)
stacks = []   # (thread, [frames leaf first])
for block in out.split('shared cache slide')[1:]:
    for m in re.finditer(r'thread (\d+): pc (0x[0-9a-f]+) lr 0x[0-9a-f]+\n  bt ([0-9a-fx ]+)', block):
        stacks.append((int(m.group(1)), [int(m.group(2), 16)] + [int(x, 16) for x in m.group(3).split()]))
addrs = sorted({a for _, f in stacks for a in f})
names = {}
def atos(obj, base, group):
    if not group:
        return
    r = subprocess.run(['atos', '-o', obj, '-l', hex(base)] + [hex(a) for a in group], capture_output=True, text=True)
    for a, n in zip(group, r.stdout.strip().split('\n')):
        names[a] = re.sub(r' \(in [^)]*\)', '', n)
sm2 = [a for a in addrs if sm2_base <= a < sm2_base + 0x4000000 and a < tu_base or (sm2_base <= a < tu_base)]
tu = [a for a in addrs if tu_base <= a < tu_base + 0x2000000]
atos(ROOT + '/phone/metal2/out/SweetMetal2.dSYM', sm2_base, sm2)
atos(ROOT + '/work/turnip/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib', tu_base, tu)
for a in addrs:
    if a in names:
        continue
    if a >= 0x180000000 + slide:
        r = subprocess.run(['ipsw', 'dyld', 'a2s', ROOT + '/research/dsc/dyld_shared_cache_arm64', hex(a), '-s', hex(slide),
                            '--cache', ROOT + '/work/a2s.cache'], capture_output=True, text=True)
        names[a] = re.sub(r'^0x[0-9a-f]+: ', '', (r.stdout.strip() or '?').split('\n')[-1])
    else:
        names[a] = hex(a)
idle = re.compile(r'mach_msg|__workq_kernreturn|__psynch_cvwait|semaphore_wait|__ulock_wait|kevent|__select|poll$')
leaf, incl = collections.Counter(), collections.Counter()
for th, f in stacks:
    syms = [names.get(a, hex(a)) for a in f]
    if idle.search(syms[0]) or (len(syms) > 1 and idle.search(syms[1])):
        continue
    leaf[syms[0]] += 1
    for s in set(syms):
        incl[s] += 1
busy = sum(leaf.values())
print('%d stacks sampled, %d busy' % (len(stacks), busy))
print('-- leaf'); [print('%4d %s' % (n, s[:150])) for s, n in leaf.most_common(25)]
print('-- inclusive'); [print('%4d %s' % (n, s[:150])) for s, n in incl.most_common(40)]
