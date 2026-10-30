#!/bin/bash
# p4-shot.sh NAME: full-res screenshot of the buffer on screen (direct scanout slot or blit fb) -> logs/bench/p4-NAME.png
cd $HOME/mnt/iOS_Pixel5/agent; P=$HOME/mnt/iOS_Pixel5; W=/mnt/c/ClaudeProjects/iOS_Pixel5
ask(){ echo "$2" > inbox/$1.req; for i in $(seq ${3:-60}); do [ -f outbox/$1.out ] && break; sleep 1; done; cat outbox/$1.out 2>/dev/null || echo "no-answer $1"; }
u=$(date +%s%N | tail -c 7); rm -f tmp/p4-vig0 tmp/p4-raw
ask p4-sv$u "files read /dev/pmem 0x0ae05000 64 $W/agent/tmp/p4-vig0" 30 >/dev/null
KF=$P/$(python3 -c 'import json;print(json.load(open("'$P'/logs/mon/now.json"))["klog"]["file"])')
w=$(python3 -I $P/tools-claude/fb-shot.py --where tmp/p4-vig0 "$KF"); echo "where: $w"
read -r kind pa len geo _ <<<"$w"
ask p4-sr$u "files read /dev/pmem $pa $len $W/agent/tmp/p4-raw" 90 >/dev/null
if [ "$geo" = - ] || [ -z "$geo" ]; then python3 -I $P/tools-claude/fb-shot.py tmp/p4-raw $P/logs/bench/p4-$1.png 1
else python3 -I $P/tools-claude/fb-shot.py tmp/p4-raw $P/logs/bench/p4-$1.png 1 "$geo"; fi
ls -la $P/logs/bench/p4-$1.png
