#!/bin/sh
# Phone in fastboot -> TWRP with adb, for reading logs (tools/flame-log-pull.sh).
#
# `fastboot set_active a` first: every boot takes a retry from the active
# slot and nothing marks one successful, so after a few test runs both slots
# are "unbootable". ABL then still accepts `fastboot boot`, but TWRP's first
# stage init cannot mount its slot partitions and reboots into fastboot
# about 14 s later.
set -eu
cd "$(dirname "$0")/.."
for i in $(seq 1 60); do fastboot devices | grep -q . && break; sleep 1; done
fastboot set_active a 2>&1 | tail -1
# ABL drops off USB for a moment after set_active; boot only once it answers.
sleep 2
for i in $(seq 1 30); do fastboot getvar product >/dev/null 2>&1 && break; sleep 1; done
fastboot boot downloads/twrp/twrp-3.7.1_12-0-flame.img 2>&1 | tail -1
for i in $(seq 1 60); do
	adb devices | grep -q recovery && { echo "TWRP up after ${i}s"; exit 0; }
	sleep 1
done
echo "TWRP did not come up (fastboot: $(fastboot devices | wc -l | tr -d ' '))" >&2
exit 1
