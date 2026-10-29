#!/bin/bash
# redfin-fpsbench.sh LABEL [KLOG_PA]: fixed touch script over the kernel command server, then one row in
# logs/fpsbench2.tsv and the median/spread of all rows with the same LABEL (run it N times for "repeat N").
# Coordinates are panel pixels (1080x2340 portrait), as the kernel's tap/swipe commands take them.
#
# u-prof rework (2026-10-27):
#  - no power key by default: the display state is read first ("p disp" on 0991 kernels, else the last
#    "SWEET FB: display on/off" line in the log tail); the key is pressed only when the display is off, then
#    checked again (WAKE=0: never press; the run stops if the display is off). The states go into the TSV.
#  - Settings is killed before the tap and must be running 2.5 s after it (cold start, root page, every run);
#    one retry from the home screen, else the row says settings=miss.
#  - phases: "p phase NAME" before each gesture group (0991 kernels flush the FB/SCANOUT/GPU windows there, so
#    every stats line belongs to one phase; older kernels: attributed by time). fps counts panel-buffer frames
#    (FB shown) plus direct-scanout frames (SCANOUT latched).
#  - CPU: backboardd/SpringBoard CPU seconds over the run (psx over SSH).
#  - PROF=HZ: the kernel sampler on backboardd for the whole run (0991; p prof dump line in the log).
#
# v3 (2026-10-29, old script kept as redfin-fpsbench.sh.v2):
#  - TEMP_MAX / TEMP_WAIT_S (fpsbench.conf): wait until sweetmon's now.json temp.max <= TEMP_MAX (at most TEMP_WAIT_S);
#    start temp + wait go into new TSV columns.
#  - Settings via `openapp com.apple.Preferences` over SSH (the home-page-2 tap only as fallback): column 'set via'.
#  - deterministic home page 1 before the pages and cc phases: panel-buffer screenshot (/dev/pmem 0xa0000000) is
#    classified against tools-claude/fbref/*.feat (page1/page2/ccopen/settings-*) by fb-shot.py, then fixed
#    (swipe right / home) and checked again; tries in 'pg1 tries *' columns.
#  - a screenshot at the start of each measured phase -> logs/bench/RUN-PHASE.png, class in 'chk *' columns
#    (settings: ps=ok|no + screenshot class).
#  - one CC open/close warm-up before the timed cc phase.
#  - phases parsed from sweetmon's klog file (logs/mon/klog-<boot>.txt via now.json klog.file); the old end-of-run
#    klog.py pull only when that file is not growing or lacks the end marker ('klog src' column: mon|pull).
set -uo pipefail
P=/mnt/c/ClaudeProjects/iOS_Pixel5
REPO=${REPO:-$HOME/ios-redfin}
LABEL=${1:-run}; PA=${2:-}
# default klog PA: the one sweetmon found for the running kernel (now.json klog.pa), else the old constant
[ -z "$PA" ] && PA=$(python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["klog"]["pa"])
except Exception: pass' "$P/logs/mon/now.json" 2>/dev/null)
[[ $PA =~ ^0x[0-9a-fA-F]+$ ]] || PA=0x101d4a8d8
[[ $LABEL =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad label"; exit 1; }
cd "$REPO" || exit 1
# settings without an agent action change: KEY=VALUE lines in agent/tmp/fpsbench.conf (PROF PROF_DEPTH PROF_WAIT
# WAKE SETTINGS_XY AUTOLOCK_NEVER), e.g. PROF=1000. AUTOLOCK_NEVER=1: phone/tools autolock never before the run
# (Auto-Lock stays Never afterwards; undo: phone /var/local/bin/autolock 60)
CONF=$P/agent/tmp/fpsbench.conf
if [ -f "$CONF" ]; then
	while IFS='=' read -r k v; do
		v=${v%$'\r'}
		case $k in PROF|PROF_DEPTH|PROF_WAIT|WAKE|AUTOLOCK_NEVER|TEMP_MAX|TEMP_WAIT_S|SHOTS) [[ $v =~ ^[0-9]*$ ]] && declare "$k=$v";;
		SETTINGS_XY) [[ $v =~ ^[0-9]+\ [0-9]+$ ]] && SETTINGS_XY=$v;; esac
	done < "$CONF"
fi
c() { timeout 15 python3 -I tools/flame-cmd.py --wait 1 "$*" | grep -v 'bytes:' ; }
s() { sleep "$1"; }
ph() { timeout 20 ssh -i ~/.ssh/redfin-claude -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=5 -o LogLevel=ERROR root@192.168.7.2 "$@" 2>/dev/null; }
ping -c 1 -W 2 192.168.7.2 >/dev/null || { echo "phone not reachable"; exit 1; }
SSH=0; ph true && SSH=1
# display state: on | off | unknown (an old kernel without p disp and no display line in the last 256 KiB)
disp() {
	c "p disp" >/dev/null; s 0.4
	local l; l=$(timeout 60 python3 "$P/tools-claude/klog-tail.py" "$PA" 262144 2>/dev/null | tr -d '\0' | grep -a -o 'SWEET FB: display o[nf]*' | tail -1)
	case $l in *on) echo on;; *off) echo off;; *) echo unknown;; esac
}
cpus() { ph "/var/local/bin/psx $1" | awk -v n="$1" '$5 == n { print $4; exit }'; }
home() { c swipe 540 2335 540 1500 120; s 1.2; }
RUN=$LABEL-$(date +%H%M%S)
mkdir -p "$P/logs/bench"
RAW=/tmp/fpsbench-$$.raw
# shot [NAME]: the buffer on screen -> class word (fb-shot.py CLASS:DIST:LUM, or noshot); NAME: also logs/bench/RUN-NAME.png
# sc1: VIG0's SRC0_ADDR (64 bytes of /dev/pmem 0x0ae05000, read-only) + fb-shot.py --where: in direct scanout the latched
# slot surface (1125x2436, rows = YSTRIDE0), else the old panel buffer at 0xa0000000. SHOTSRC = last source used.
shot() {
	[ "${SHOTS:-1}" = 0 ] && { echo off; return; }
	local png=/tmp/fpsbench-$$.png rg=/tmp/fpsbench-$$.vig0 kind=blit pa=0xa0000000 len=10183680 geo=- w
	[ -n "${1:-}" ] && png=$P/logs/bench/$RUN-$1.png
	rm -f "$RAW" "$rg"
	(cd "$REPO" && timeout 20 python3 -I tools/flame-files.py read /dev/pmem 0x0ae05000 64 "$rg") >/dev/null 2>&1
	w=$(python3 -I "$P/tools-claude/fb-shot.py" --where "$rg" "${KF:-}" 2>/dev/null)
	[[ $w =~ ^(direct|blit)\ 0x[0-9a-f]+\ [0-9]+\  ]] && read -r kind pa len geo _ <<<"$w"
	SHOTSRC=$kind
	rm -f "$rg"
	(cd "$REPO" && timeout 40 python3 -I tools/flame-files.py read /dev/pmem "$pa" "$len" "$RAW") >/dev/null 2>&1
	[ -s "$RAW" ] || { echo noshot; return; }
	if [ "$geo" = - ]; then python3 -I "$P/tools-claude/fb-shot.py" "$RAW" "$png" 3 2>/dev/null || echo noshot
	else python3 -I "$P/tools-claude/fb-shot.py" "$RAW" "$png" 3 "$geo" 2>/dev/null || echo noshot; fi
	rm -f "$RAW"
}
# page1 [NAME]: get to home page 1 and check it by screenshot; echoes "TRIES CLASS" (TRIES "fail" after 4 looks)
page1() {
	local i k	# gesture output goes to stderr: stdout is only the result line
	for i in 1 2 3 4; do
		k=$(shot); case $k in
		page1:*) echo "$i $k"; return;;
		page2:*) c swipe 180 1200 900 1200 250 >&2; s 1.2;;
		ccopen:*) c swipe 540 2335 540 1200 150 >&2; s 1.5;;
		noshot|off) { home; home; } >&2; echo "- $k"; return;;
		*) home >&2; s 0.5;;
		esac
	done
	echo "fail $k"
}
# temperature gate (sweetmon now.json temp.max; skipped when now.json is missing or older than 30 s)
mtemp() { python3 -I -c 'import json,sys,time
try:
    d=json.load(open(sys.argv[1])); print("%.1f" % d["temp"]["max"] if time.time()-d["t"] < 30 else "stale")
except Exception: print("none")' "$P/logs/mon/now.json"; }
TW0=$(date +%s); TEMP0=$(mtemp)
if [ -n "${TEMP_MAX:-}" ]; then
	while [[ $TEMP0 =~ ^[0-9.]+$ ]] && awk -v a="$TEMP0" -v b="$TEMP_MAX" 'BEGIN { exit !(a > b) }' &&
		[ $(( $(date +%s) - TW0 )) -lt "${TEMP_WAIT_S:-180}" ]; do s 10; TEMP0=$(mtemp); done
fi
TWAIT=$(( $(date +%s) - TW0 ))
echo "temp at start: $TEMP0 (waited ${TWAIT}s, TEMP_MAX ${TEMP_MAX:-none})"
# sweetmon's klog file and its size before the run
KF=$(python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["klog"]["file"])
except Exception: pass' "$P/logs/mon/now.json")
[ -n "$KF" ] && KF=$P/$KF
KS0=$(stat -c %s "$KF" 2>/dev/null || echo 0)
[ "${AUTOLOCK_NEVER:-0}" = 1 ] && [ $SSH = 1 ] && ph "/var/local/bin/autolock never"
c tap 540 40	# keep-alive: a status-bar tap resets the idle (dim/auto-lock) timer and does nothing on the lock or home screen
s 0.5
D0=$(disp)
if [ "$D0" = off ]; then
	[ "${WAKE:-1}" = 0 ] && { echo "display off (WAKE=0): not running"; exit 2; }
	c key 0 100; s 1.5; D0=$(disp)
	echo "display was off: power key pressed, now $D0"
	[ "$D0" = off ] && { echo "display still off after the power key: not running"; exit 2; }
	D0=woken
fi
echo "display at start: $D0"
c "fpsbench-start $RUN"
B0=$(cpus backboardd); S0=$(cpus SpringBoard); T0=$(date +%s.%N)
[ -n "${PROF:-}" ] && c "p prof start backboardd ${PROF} 120 ${PROF_DEPTH:-24} ${PROF_WAIT:-0}"
c "p phase unlock"
c swipe 540 2335 540 900 200; s 1.5; home; home
read -r PG1P _ <<<"$(page1)"
CHKP=$(shot pages)
echo "pages: page1 tries $PG1P, screenshot $CHKP"
c "p phase pages"
for i in 1 2 3 4 5; do c swipe 900 1200 180 1200 250; s 0.8; done
for i in 1 2 3 4 5; do c swipe 180 1200 900 1200 250; s 0.8; done
SETTINGS_XY="${SETTINGS_XY:-914 290}"  # Settings icon: home page 2, top right (seen on fb-c47)
c "p phase launch"
[ $SSH = 1 ] && ph "/var/local/bin/psx -k Preferences" >/dev/null
home; home
tapset() { page1 >/dev/null; c swipe 900 1200 180 1200 250; s 1.2; c tap $SETTINGS_XY; s 2.5; }
SET=unknown; SETVIA=tap	# (no SSH: cannot tell, and no openapp)
if [ $SSH = 1 ]; then
	SET=ok; SETVIA=openapp
	ph "/var/local/bin/openapp com.apple.Preferences" >/dev/null; s 2.5
	if ! ph "/var/local/bin/psx Preferences" | grep -q Preferences; then
		SET=retry; SETVIA=tap; tapset; s 0.5
		ph "/var/local/bin/psx Preferences" | grep -q Preferences || SET=miss
	fi
else
	tapset
fi
echo "settings: $SET via $SETVIA"
CHKS=$(shot settings)
PSOK=no; [ $SSH = 1 ] && ph "/var/local/bin/psx Preferences" | grep -q Preferences && PSOK=ok
CHKS="ps=$PSOK,$CHKS"
echo "settings check: $CHKS"
c "p phase settings"
for i in $(seq 10); do c swipe 540 1900 540 600 120; s 1.2; done
c "p phase home"
home; home
c swipe 1000 5 1000 1100 250; s 1.5; c swipe 540 2335 540 1200 150; s 1.5	# CC warm-up open/close (not timed)
read -r PG1C _ <<<"$(page1)"
CHKC=$(shot cc)
echo "cc: page1 tries $PG1C, screenshot $CHKC"
c "p phase cc"
for i in 1 2 3; do c swipe 1000 5 1000 1100 250; s 1.5; c swipe 540 2335 540 1200 150; s 1.5; done
home
c "p phase idle"
s 6	# let the last 5-s stats window land
c "p phase end"
B1=$(cpus backboardd); S1=$(cpus SpringBoard); T1=$(date +%s.%N)
[ -n "${PROF:-}" ] && c "p prof dump"
c "p disp"
c "fpsbench-end $RUN"
s 1
# phases from sweetmon's klog file (it streams the whole log); the end-of-run pull only as a fallback
KSRC=pull; KLOG=$P/logs/klog.txt; SEG=/tmp/fpsbench-$$.klog
if [ -n "$KF" ] && [ "$(stat -c %s "$KF" 2>/dev/null || echo 0)" -gt "$KS0" ]; then
	for i in $(seq 15); do
		tail -c +$((KS0 + 1)) "$KF" | tr -d '\0' > "$SEG"
		grep -a -q "fpsbench-end $RUN" "$SEG" && grep -a -q "fpsbench-start $RUN" "$SEG" && { KSRC=mon; KLOG=$SEG; break; }
		s 1
	done
fi
[ $KSRC = pull ] && timeout 300 python3 "$P/tools-claude/klog.py" "$PA" >/dev/null
echo "klog source: $KSRC"
D1=$(tr -d '\0' < "$KLOG" | grep -a -o 'SWEET FB: display o[nf]*' | tail -1 | awk '{print $NF}')
cpu() { [ -n "$1" ] && [ -n "$2" ] && awk -v a="$1" -v b="$2" -v t0="$T0" -v t1="$T1" 'BEGIN { printf "%.1f", 100 * (b - a) / (t1 - t0) }' || echo -; }
python3 -I "$P/tools-claude/fps-parse.py" "$KLOG" "$RUN" "$P/logs/fpsbench2.tsv" \
	disp0="$D0" disp1="${D1:-unknown}" settings="$SET" bbd_cpu="$(cpu "$B0" "$B1")" sb_cpu="$(cpu "$S0" "$S1")" \
	temp0="$TEMP0" twait="$TWAIT" setvia="$SETVIA" pg1_pages="${PG1P:--}" pg1_cc="${PG1C:--}" chk_pages="$CHKP" \
	chk_settings="$CHKS" chk_cc="$CHKC" ksrc="$KSRC"
if [ -n "${PROF:-}" ]; then grep -a "SWEET PROF: \(done\|dump\)" "$KLOG" | tail -1; fi
rm -f "$SEG" /tmp/fpsbench-$$.png
