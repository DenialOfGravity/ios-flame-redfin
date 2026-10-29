#!/bin/bash
# devices/redfin/pull-soc.sh [--check]: pull the Pixel 5's own device tree over adb (the live FDT ABL hands
# over, /sys/firmware/fdt) and print the SM7250 addresses the port hard-codes (tools/soc-args.py), writing
# them to devices/redfin/soc.args. --check: compare them with the values the code uses instead (exit 1 on a
# difference). The vayu port's pull-soc.sh convention.
#
# The phone: Android with adb, or TWRP (adb root). Read-only on the phone. The tree itself carries the serial
# number, so it is only kept in a temp dir and removed; soc.args holds addresses and the model string only.
# Where only root can read /sys/firmware/fdt, it is copied under su to a staging file, pulled, and removed.
set -e -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
adb get-state >/dev/null
if ! adb pull /sys/firmware/fdt "$tmp/fdt" >/dev/null 2>&1; then
	stage=/data/local/tmp/redfin-fdt
	adb shell "su -c 'cat /sys/firmware/fdt > $stage && chmod 644 $stage'" >/dev/null 2>&1 || true
	got=0; adb pull "$stage" "$tmp/fdt" >/dev/null 2>&1 || got=1
	adb shell "su -c 'rm -f $stage'" >/dev/null 2>&1 || true
	[ "$got" -eq 0 ] || { echo "pull-soc.sh: cannot read /sys/firmware/fdt over adb, with or without su"; exit 1; }
fi
if [ "${1:-}" = --check ]; then
	exec python3 -I tools/soc-args.py "$tmp/fdt" --check
fi
# made aside and copied over, so that a failure leaves the soc.args that was there
python3 -I tools/soc-args.py "$tmp/fdt" > "$tmp/soc.args"
cp "$tmp/soc.args" "$here/soc.args"
cat "$here/soc.args"
echo "pull-soc.sh: wrote ${here#$PWD/}/soc.args (python3 -I tools/soc-args.py DTB --check compares with the code)"
