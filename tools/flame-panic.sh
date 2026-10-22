#!/bin/bash
# Symbolicate the panic(s) in a flame-run directory: the panic string, the
# panicking thread's backtrace and the other cores' PCs, against the run's own
# kernel (logs/runs/NAME/kernel), slide from "Kernel text base".
#   tools/flame-panic.sh NAME        (or a path to a log file + -k KERNEL)
set -euo pipefail
cd "$(dirname "$0")/.."
log=${1:?run name}; kernel=""
if [ -d "logs/runs/$log" ]; then kernel=logs/runs/$log/kernel; log=logs/runs/$log/rescue.txt; fi
[ "${2:-}" = "-k" ] && kernel=$3
base=$(/usr/bin/grep -a -m1 -o "Kernel text base: *0x[0-9a-f]*" "$log" | /usr/bin/grep -o "0x[0-9a-f]*$" || true)
[ -n "$base" ] || { echo "no panic report with a text base in $log"; exit 1; }
/usr/bin/grep -a -m1 "panic(cpu" "$log" | cut -c1-240
addrs=$( (/usr/bin/grep -a -o "lr: 0x[0-9a-f]*" "$log"; /usr/bin/grep -a -o "CORE [0-9]*: PC=0x[0-9a-f]*" "$log") | /usr/bin/grep -o "0x[0-9a-f]*" | awk '!s[$0]++')
echo "--- backtrace (panicking thread first), kernel $kernel, text base $base"
xcrun atos -o "$kernel" -arch arm64 -l "$base" $addrs 2>/dev/null | paste <(echo "$addrs") - | head -40
