#!/bin/bash
# p4-census.sh TAG: open Settings, 10 down + 10 up scrolls, save tu-draw/T 5s lines to tmp/p4-census-TAG.txt and summarize
cd $HOME/mnt/iOS_Pixel5/agent
ask(){ echo "$2" > inbox/$1.req; for i in $(seq ${3:-60}); do [ -f outbox/$1.out ] && break; sleep 1; done; cat outbox/$1.out 2>/dev/null || echo "no-answer $1"; }
u=$(date +%s%N | tail -c 7)
ask p4-co$u "phone /var/local/bin/openapp com.apple.Preferences; sleep 2; echo opened" 30 >/dev/null
K=$(ls -t ../logs/mon/klog-*.txt | head -1); T0=$(tail -1 $K | grep -o '^\[[0-9.]*' | tr -d '[')
for x in a b c d e f g h i j; do ask p4-cd$u$x "poke swipe 540 1900 540 600 120" 15 >/dev/null; sleep 0.5; done
for x in a b c d e f g h i j; do ask p4-cu$u$x "poke swipe 540 600 540 1900 120" 15 >/dev/null; sleep 0.3; done
sleep 6
awk -F'[][]' -v t=$T0 '$2+0>t' $K | grep -a 'T tu-draw\|native-metal: T 5s\|SWEET GPU: 5s' > tmp/p4-census-$1.txt
python3 - tmp/p4-census-$1.txt <<'PY'
import re,sys
fr=None
for l in open(sys.argv[1],errors='ignore'):
    m=re.search(r'T 5s: frames (\d+)',l)
    if m: fr=int(m.group(1)); g=re.search(r'gpu ([0-9.]+)/',l); gm=g.group(1) if g else '?'
    m=re.search(r'tu-draw: fs (\d+) shaders (\d+) draws: split (\d+) passes ([0-9.]+)ms = first ([0-9.]+) \+ draws ([0-9.]+).*?#(\d+) ([0-9.]+)ms/(\d+) ([0-9.]+)us a(\d+)k \S+ \S+ d\d+ i(\d+) r(\S+)',l)
    if m and fr:
        print(f"frames {fr:3d} gpu {gm}ms | draws/f {int(m.group(2))/fr:5.1f} passes/f {int(m.group(3))/fr:4.1f} pass-ms/f {float(m.group(4))/fr:5.2f} | top #{m.group(7)} {float(m.group(8))/fr:5.2f}ms/f {m.group(10)}us a{m.group(11)}k i{m.group(12)} r{m.group(13)}")
PY
grep -a 'T tu-draw' tmp/p4-census-$1.txt | tail -1 | grep -o '#[0-9]* [0-9.]*ms/[0-9]* [0-9.]*us a[0-9]*k [^;]*' | head -5
