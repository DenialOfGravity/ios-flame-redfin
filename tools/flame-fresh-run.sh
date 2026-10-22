#!/bin/bash
# Fresh phone run: reboot whatever runs now, boot $FLAME_KERNEL (default kernel-0124) with GPU present, wait for SSH.
# usage: tools/flame-fresh-run.sh NAME [SECS] [EXTRA_BOOT_ARGS]   (log: logs/NAME-run.txt; SECS = flamereboot, default 1200)
cd "$(dirname "$0")/.."
name=$1; secs=${2:-1200}; extra=${3:-}
python3 tools/flame-cmd.py reboot >/dev/null 2>&1
for i in $(seq 1 60); do pgrep -f "^/bin/bash tools/flame-run.sh " >/dev/null || break; sleep 5; done
(tools/flame-run.sh "$name" -k ${FLAME_KERNEL:-work/boot/kernel-0124} -s "$secs" -G -a "sweetusb=2 sweetusbframes=0 $extra" > "logs/$name-run.txt" 2>&1 &)
for i in $(seq 1 80); do sleep 5; tools/flame-ssh 'ls /dev/pmem' >/dev/null 2>&1 && { echo "$name: up after $((i * 5)) s"; exit 0; }; done
echo "$name: no SSH after 400 s"; exit 1
