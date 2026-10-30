#!/bin/bash
# g9-shots.sh TAG: screenshots Settings, CC, Home, Safari, Photos -> logs/bench/p4-g9-TAG-{settings,cc,home,safari,photos}.png
cd $HOME/mnt/iOS_Pixel5/agent
ask(){ echo "$2" > inbox/$1.req; for i in $(seq ${3:-60}); do [ -f outbox/$1.out ] && break; sleep 1; done; cat outbox/$1.out 2>/dev/null || echo "no-answer $1"; }
u=$(date +%s%N | tail -c 7); T=$1
ask g9-so$u "phone /var/local/bin/openapp com.apple.Preferences; sleep 3; echo ok" 30 >/dev/null
bash tmp/p4-shot.sh g9-$T-settings | tail -1
ask g9-sc$u "poke swipe 1000 5 1000 1100 250" 15 >/dev/null; sleep 2.5
bash tmp/p4-shot.sh g9-$T-cc | tail -1
ask g9-sx$u "poke swipe 540 2335 540 1500 120" 15 >/dev/null; sleep 1.5
ask g9-sh$u "poke swipe 540 2335 540 1500 120" 15 >/dev/null; sleep 2.5
bash tmp/p4-shot.sh g9-$T-home | tail -1
ask g9-sa$u "phone /var/local/bin/openapp com.apple.mobilesafari; sleep 5; echo ok" 30 >/dev/null
bash tmp/p4-shot.sh g9-$T-safari | tail -1
ask g9-sp$u "phone /var/local/bin/openapp com.apple.mobileslideshow; sleep 5; echo ok" 30 >/dev/null
bash tmp/p4-shot.sh g9-$T-photos | tail -1
ask g9-sb$u "poke swipe 540 2335 540 1500 120" 15 >/dev/null; sleep 1
