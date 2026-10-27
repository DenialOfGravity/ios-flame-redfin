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
set -uo pipefail
P=/mnt/c/ClaudeProjects/iOS_Pixel5
REPO=${REPO:-$HOME/ios-redfin}
LABEL=${1:-run}; PA=${2:-0x101d4a8d8}
[[ $LABEL =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad label"; exit 1; }
cd "$REPO" || exit 1
# settings without an agent action change: KEY=VALUE lines in agent/tmp/fpsbench.conf (PROF PROF_DEPTH PROF_WAIT
# WAKE SETTINGS_XY AUTOLOCK_NEVER), e.g. PROF=1000. AUTOLOCK_NEVER=1: phone/tools autolock never before the run
# (Auto-Lock stays Never afterwards; undo: phone /var/local/bin/autolock 60)
CONF=$P/agent/tmp/fpsbench.conf
if [ -f "$CONF" ]; then
	while IFS='=' read -r k v; do
		v=${v%$'\r'}
		case $k in PROF|PROF_DEPTH|PROF_WAIT|WAKE|AUTOLOCK_NEVER) [[ $v =~ ^[0-9]*$ ]] && declare "$k=$v";;
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
c "p phase pages"
for i in 1 2 3 4 5; do c swipe 900 1200 180 1200 250; s 0.8; done
for i in 1 2 3 4 5; do c swipe 180 1200 900 1200 250; s 0.8; done
SETTINGS_XY="${SETTINGS_XY:-914 290}"  # Settings icon: home page 2, top right (seen on fb-c47)
c "p phase launch"
[ $SSH = 1 ] && ph "/var/local/bin/psx -k Preferences" >/dev/null
home; home; c swipe 900 1200 180 1200 250; s 1.2; c tap $SETTINGS_XY; s 2.5
SET=unknown	# (no SSH: cannot tell)
if [ $SSH = 1 ]; then
	SET=ok
	if ! ph "/var/local/bin/psx Preferences" | grep -q Preferences; then
		SET=retry; home; home; c swipe 900 1200 180 1200 250; s 1.5; c tap $SETTINGS_XY; s 3
		ph "/var/local/bin/psx Preferences" | grep -q Preferences || SET=miss
	fi
fi
echo "settings: $SET"
c "p phase settings"
for i in $(seq 10); do c swipe 540 1900 540 600 120; s 1.2; done
c "p phase home"
home; home
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
timeout 300 python3 "$P/tools-claude/klog.py" "$PA" >/dev/null
D1=$(tr -d '\0' < "$P/logs/klog.txt" | grep -a -o 'SWEET FB: display o[nf]*' | tail -1 | awk '{print $NF}')
cpu() { [ -n "$1" ] && [ -n "$2" ] && awk -v a="$1" -v b="$2" -v t0="$T0" -v t1="$T1" 'BEGIN { printf "%.1f", 100 * (b - a) / (t1 - t0) }' || echo -; }
python3 -I "$P/tools-claude/fps-parse.py" "$P/logs/klog.txt" "$RUN" "$P/logs/fpsbench2.tsv" \
	disp0="$D0" disp1="${D1:-unknown}" settings="$SET" bbd_cpu="$(cpu "$B0" "$B1")" sb_cpu="$(cpu "$S0" "$S1")"
if [ -n "${PROF:-}" ]; then grep -a "SWEET PROF: \(done\|dump\)" "$P/logs/klog.txt" | tail -1; fi
