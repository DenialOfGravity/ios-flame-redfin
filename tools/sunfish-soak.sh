#!/bin/bash
# Soak test: every 60 s log phone uptime (boot time), battery and new panics/crashes
# from the live log into LOGFILE. Survives phone reboots (marks them).
#   tools/sunfish-soak.sh LOGFILE [LIVELOG]
cd "$(dirname "$0")/.." || exit 1
out=${1:?usage: $0 LOGFILE [LIVELOG]} live=${2:-../logs/usb-live.log}
last_lines=$(wc -l < "$live")
last_boot=
while true; do
	now=$(date +%T)
	boot=$(timeout 15 tools/sunfish-ssh 'date -r /var/run/syslog.pid +%s 2>/dev/null || ls -ld --full-time /var/run | cut -c1-60' 2>/dev/null | tr -d '\r')
	batt=$(grep -a 'SWEET BATTERY' "$live" | tail -1 | grep -oE 'shown [0-9]+%|[0-9]+%' | tail -1)
	lines=$(wc -l < "$live")
	new=$(tail -n $((lines - last_lines)) "$live" | grep -acE 'panic|CRASH [^ ]+\[')
	last_lines=$lines
	state=up; [ -z "$boot" ] && state=unreachable
	[ -n "$boot" ] && [ -n "$last_boot" ] && [ "$boot" != "$last_boot" ] && state="REBOOTED"
	[ -n "$boot" ] && last_boot=$boot
	echo "$now $state battery=${batt:-?} new_crash_or_panic_lines=$new" >> "$out"
	sleep 60
done
