#!/bin/bash
# p5-trace.sh NAME: open Settings, start kdebug trace NAME 8s, scroll 6 down + 6 up, mon wait 60, print results
cd $HOME/mnt/iOS_Pixel5/agent
ask(){ echo "$2" > inbox/$1.req; for i in $(seq ${3:-60}); do [ -f outbox/$1.out ] && break; sleep 1; done; cat outbox/$1.out 2>/dev/null || echo "no-answer $1"; }
u=$(date +%s%N | tail -c 7)
ask p5-to$u "phone /var/local/bin/openapp com.apple.Preferences; sleep 2; echo opened" 30 >/dev/null
K=$(ls -t ../logs/mon/klog-*.txt | head -1); T0=$(tail -1 $K | grep -o '^\[[0-9.]*' | tr -d '[')
ask p5-tt$u "mon trace $1 kdebug 8 app=Preferences" 20 | tail -3
for x in a b c d e f; do ask p5-td$u$x "poke swipe 540 1900 540 600 120" 15 >/dev/null; sleep 0.5; done
for x in a b c d e f; do ask p5-tu$u$x "poke swipe 540 600 540 1900 120" 15 >/dev/null; sleep 0.3; done
sleep 6
ask p5-tw$u "mon wait 60" 75 | tail -25
awk -F'[][]' -v t=$T0 '$2+0>t' $K | grep -a 'SCANOUT: 5s frames\|SWEET UI: bigcore\|vsync lock\|SCANOUT: 5s:' | cut -c1-330
