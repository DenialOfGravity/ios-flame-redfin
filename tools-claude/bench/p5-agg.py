import re,sys
# p5-agg.py KLOG T0 T1 : aggregate SCANOUT 5s frames + bigcore + vsync lock lines in [T0,T1]
k,t0,t1=sys.argv[1],float(sys.argv[2]),float(sys.argv[3])
v=[0]*4;p50=[];p95=[];mx=0;jit=[];tl50=[];tl95=[];rep=0;big=[0,0,0,0];lock=[]
for l in open(k,errors='ignore'):
    m=re.match(r'\[\s*([0-9.]+)\]',l)
    if not m or not t0<=float(m.group(1))<=t1: continue
    m=re.search(r'5s frames: latches (\d+) \| vsyncs 1:(\d+) 2:(\d+) 3:(\d+) 4\+:(\d+) \| p50 ([0-9.]+) p95 ([0-9.]+) max ([0-9.]+) ms \| jitter (\d+) us \| repeats>=3 (\d+).*touch->latch n (\d+) p50 (\d+) p95 (\d+)',l)
    if m and int(m.group(1))>=25:
        for i in range(4): v[i]+=int(m.group(2+i))
        p50.append(float(m.group(6)));p95.append(float(m.group(7)));mx=max(mx,float(m.group(8)));jit.append(int(m.group(9)));rep+=int(m.group(10))
        if int(m.group(11)): tl50.append(int(m.group(12)));tl95.append(int(m.group(13)))
    m=re.search(r'bigcore 5s: runs big/little, ms: display (\d+)/(\d+), (\d+)/(\d+)',l)
    if m: big=[a+int(b) for a,b in zip(big,m.groups())]
    if 'vsync lock' in l: lock.append(l.strip()[:260])
med=lambda a: sorted(a)[len(a)//2] if a else 0
print(f"windows {len(p50)} vsyncs 1:{v[0]} 2:{v[1]} 3:{v[2]} 4+:{v[3]} | p50 med {med(p50)} p95 med {med(p95)} max {mx} | jitter med {med(jit)} us | repeats>=3 {rep} | touch->latch p50 med {med(tl50)} p95 med {med(tl95)}")
print(f"bigcore display runs big/little {big[0]}/{big[1]}, ms {big[2]}/{big[3]}")
for x in lock[-3:]: print(x)
