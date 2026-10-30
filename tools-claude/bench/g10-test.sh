#!/bin/bash
# g10-test.sh: phone test of r70-gpu (ws-z-g10, SWEET_DEADFILL default 2). PREPARED, NOT RUN. Run only when the coordinator says the phone is free.
# Steps (status lines -> tmp/status-g10t.txt):
#  0 record installed bundle/env/live            1 install r70-gpu (backup /var/local/SweetMetal2.bundle.pre-g10, live .pre-g10), DEADFILL line removed
#  2 DRAWBOX Settings + CC (default mode)        3 census (GPU ms/frame)      4 swipe trace       5 screenshots + diff vs p4-g9-off
# PASS: DB shows on the 1125x2436 IOSurface pass: d0..d3 'DF dropped' and the surviving fill 'DF cleared (load->clear ...)' (no 'DF no clear');
#       'DF 5s' lines: mode 2, held_passes >0, cleared >0, no_clear ~0; census GPU ms/f <= g9 df1 (7.9); no refused command buffers;
#       g10-diff: settings/cc/safari max <=2 per channel outside the status bar (rows <150), home widgets/clock and photos content excluded.
# REVERT: ask X "phone rm -rf /System/Library/Extensions/SweetMetal2.bundle && mv /var/local/SweetMetal2.bundle.pre-g10 /System/Library/Extensions/SweetMetal2.bundle && cp /var/local/mtl2-live.pre-g10 /var/local/mtl2-live; /var/local/bin/psx -k backboardd"
#   (live off without revert: echo SWEET_DEADFILL=0 >> /var/local/mtl2-live)
cd $HOME/mnt/iOS_Pixel5/agent; P=$HOME/mnt/iOS_Pixel5; W=/mnt/c/ClaudeProjects/iOS_Pixel5; R=r70-gpu; S=tmp/status-g10t.txt
ask(){ echo "$2" > inbox/$1.req; for i in $(seq ${3:-60}); do [ -f outbox/$1.out ] && break; sleep 1; done; cat outbox/$1.out 2>/dev/null || echo "no-answer $1"; }
u=$(date +%s%N | tail -c 7); st(){ echo "$(date -u +%H:%M) $*" | tee -a $S; }
K(){ ls -t $P/logs/mon/klog-*.txt | head -1; }
now(){ tail -1 $(K) | grep -o '^\[ *[0-9.]*' | tr -d '[ '; }
since(){ awk -F'[][]' -v t=$1 '$2+0>t' $(K); }
BIN=$(awk '/SweetMetal2.bundle\/SweetMetal2 /{print $2}' $P/$R/INSTALL.txt | head -1); DYL=$(awk '/libvulkan_freedreno.dylib /{print $2}' $P/$R/INSTALL.txt | head -1)
st "g10t start (bundle $BIN)"
# 0
ask g10-0$u "phone toybox sha256sum /System/Library/Extensions/SweetMetal2.bundle/SweetMetal2; ls -d /var/local/SweetMetal2.bundle.* 2>&1; cat /var/local/mtl2-env; echo ---; cat /var/local/mtl2-live" 30 | tee tmp/g10t-before.txt
grep -q 'SweetMetal2.bundle.pre-g10' tmp/g10t-before.txt && { st "STOP: /var/local/SweetMetal2.bundle.pre-g10 exists"; exit 1; }
# 1 copy + verify + swap. The live file keeps every line but SWEET_DEADFILL (unset = the new default 2; SWEET_LUMA_BOOST stays as the user set it)
ask g10-1$u "phone rm -rf /var/local/tmp/m2-g10; mkdir -p /var/local/tmp/m2-g10/SweetMetal2.bundle/_CodeSignature" 20 >/dev/null
for f in Info.plist:644 SweetMetal2:755 libvulkan_freedreno.dylib:755 _CodeSignature/CodeResources:644; do
 ask g10-2$u${f%%[.:/]*} "files put $W/$R/SweetMetal2.bundle/${f%:*} /var/local/tmp/m2-g10/SweetMetal2.bundle/${f%:*} ${f#*:}" 90 | tail -1; done
H=$(ask g10-3$u "phone toybox sha256sum /var/local/tmp/m2-g10/SweetMetal2.bundle/SweetMetal2 /var/local/tmp/m2-g10/SweetMetal2.bundle/libvulkan_freedreno.dylib" 30)
echo "$H" | grep -q "$BIN" && echo "$H" | grep -q "$DYL" || { st "STOP: sha mismatch on phone"; echo "$H"; exit 1; }
T0=$(now)
ask g10-4$u "phone [ ! -e /var/local/SweetMetal2.bundle.pre-g10 ] && cp /var/local/mtl2-live /var/local/mtl2-live.pre-g10 && mv /System/Library/Extensions/SweetMetal2.bundle /var/local/SweetMetal2.bundle.pre-g10 && mv /var/local/tmp/m2-g10/SweetMetal2.bundle /System/Library/Extensions/ && sed -i '/^SWEET_DEADFILL=/d;/^SWEET_DRAWBOX=/d' /var/local/mtl2-live && /var/local/bin/psx -k backboardd; sleep 40; cat /var/local/mtl2-live; echo ok" 100 | tail -4
echo "$(date -u '+%Y-%m-%d %H:%M') UTC phone: SweetMetal2 r70-gpu (ws-z-g10, SWEET_DEADFILL default 2) $BIN installed; backups /var/local/SweetMetal2.bundle.pre-g10, /var/local/mtl2-live.pre-g10 (SWEET_DEADFILL line removed from live). Revert: see agent/tmp/g10-test.sh header" >> $P/KNOWN-GOOD.txt
since $T0 | grep -a 'backboardd.*\(live:\|PR prime\|NILENC\|refused\|DF 5s\|luma\)' | tail -8 | cut -c1-220
since $T0 | grep -aq 'live:.*SWEET_DEADFILL=2' && st "1 installed, live shows SWEET_DEADFILL=2 (default)" || st "1 WARN: no 'SWEET_DEADFILL=2' live line"
# 2 DRAWBOX: Settings (3 frames), then CC (3 frames); each write of the live file re-arms
ask g10-5$u "phone /var/local/bin/openapp com.apple.Preferences; sleep 3; echo ok" 30 >/dev/null
T1=$(now); ask g10-6$u "phone echo SWEET_DRAWBOX=3 >> /var/local/mtl2-live; sleep 1; echo ok" 20 >/dev/null
ask g10-7$u "poke swipe 540 1900 540 1700 200" 15 >/dev/null; sleep 4
ask g10-8$u "poke swipe 1000 5 1000 1100 250" 15 >/dev/null; sleep 3
T2=$(now); ask g10-9$u "phone sed -i '/^SWEET_DRAWBOX=/d' /var/local/mtl2-live; echo SWEET_DRAWBOX=3 >> /var/local/mtl2-live; sleep 1; echo ok" 20 >/dev/null
ask g10-a$u "poke swipe 540 1100 540 1150 200" 15 >/dev/null; sleep 4
ask g10-b$u "phone sed -i '/^SWEET_DRAWBOX=/d' /var/local/mtl2-live; echo ok" 20 >/dev/null
ask g10-c$u "poke swipe 540 2335 540 1500 120" 15 >/dev/null; sleep 2
since $T1 | grep -a 'native-metal: DB \|DF 5s' | sed 's/^.*native-metal: //' > tmp/g10t-db.txt
st "2 DRAWBOX: $(grep -c 'pass ' tmp/g10t-db.txt) passes, dropped $(grep -c 'DF dropped' tmp/g10t-db.txt), cleared $(grep -c 'DF cleared' tmp/g10t-db.txt), no-clear $(grep -c 'DF no clear' tmp/g10t-db.txt)"
grep -E 'pass 1125x2436|DF (dropped|cleared|no clear)' tmp/g10t-db.txt | head -24 | cut -c1-160
grep 'DF 5s' tmp/g10t-db.txt | tail -3
# expect per framebuffer frame: 'd0..d3 DF dropped', 'd4 DF cleared (load->clear 0.000,0.000,0.000,1.000)' (Settings black) and nothing about no clear
# 3 census + 4 trace (g9 baselines: off 13.7 / df1 7.9 / df2 8.1 ms/f; swipe off 41 / df1 56 fps)
bash tmp/p4-census.sh g10-def | tail -4 | tee -a $S
T3=$(now); bash tmp/p5-trace.sh g10-def >/dev/null 2>&1; bash tmp/g9t-sum.sh g10-def g10-def $T3 | head -2
# 5 screenshots + diff (Settings, CC, Home, Safari, Photos) vs the g9 baseline (DEADFILL off, LUMA_BOOST=1). If the live/env has
# SWEET_LUMA_BOOST=0, set SWEET_LUMA_BOOST=1 for the shots only (the dark greys differ otherwise), then restore:
LB=$(ask g10-d$u "phone grep -h '^SWEET_LUMA_BOOST=' /var/local/mtl2-env /var/local/mtl2-live | tail -1" 20 | grep -o 'SWEET_LUMA_BOOST=[01]' | tail -1)
[ "$LB" = SWEET_LUMA_BOOST=0 ] && ask g10-e$u "phone sed -i '/^SWEET_LUMA_BOOST=/d' /var/local/mtl2-live; echo SWEET_LUMA_BOOST=1 >> /var/local/mtl2-live; sleep 2; echo ok" 20 >/dev/null
bash tmp/g9-shots.sh g10 | tail -5
[ "$LB" = SWEET_LUMA_BOOST=0 ] && ask g10-f$u "phone sed -i '/^SWEET_LUMA_BOOST=/d' /var/local/mtl2-live; echo SWEET_LUMA_BOOST=0 >> /var/local/mtl2-live; echo restored" 20
python3 tmp/g9-diff.py off g10 | tee -a $S
python3 tmp/g9-diff.py off2 g10 | tee -a $S
st "g10t END (pass: settings/cc/safari no-statusbar max <=2; home/photos content only)"
