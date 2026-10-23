#!/bin/bash
# Read the logs a test run left at the end of userdata, from TWRP (adb root) or rooted Android (su).
#
#   tools/flame-log-pull.sh shim OUT.txt   shim probe log (64 blocks before the XNU ring)
#   tools/flame-log-pull.sh xnu  OUT.bin   XNU persistent console ring (last 1025 blocks)
#   tools/flame-log-pull.sh rescue OUT.txt RAM log rescue (shim/ramlog.c: the previous kernel's
#                                          last console bytes, saved by the next shim boot)
#
# Layout: shim/ufs.h. The partition is found by name, so this works whatever
# sdaN userdata is.
set -euo pipefail
SU=${SU:-$(adb shell id -u | tr -d "\r" | grep -qx 0 && echo "" || echo "su -c")}
what=$1 out=$2
dev=$(adb shell $SU readlink -f /dev/block/by-name/userdata | tr -d '\r')
blocks=$(( $(adb shell $SU blockdev --getsize64 "$dev" | tr -d '\r') / 4096 ))
case $what in
shim) skip=$((blocks - 1025 - 64)) count=64 ;;
xnu) skip=$((blocks - 1025)) count=1025 ;;
rescue) skip=$((blocks - 1025 - 64 - 64)) count=64 ;;
*) echo "usage: $0 shim|xnu|rescue OUT" >&2; exit 2 ;;
esac
adb exec-out "$SU 'dd if=$dev bs=4096 skip=$skip count=$count 2>/dev/null'" > "$out.raw"
if [ "$what" = rescue ]; then
	python3 - "$out.raw" "$out" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
if raw[:8] != b'SWEETRSC':
    open(sys.argv[2], 'w').write('(no rescue)\n')
    sys.exit(0)
total, n = struct.unpack_from('<QI', raw, 8)
open(sys.argv[2], 'wb').write(raw[4096:4096 + n].replace(b'\0', b''))
print(f'rescue: last {n} of {total} bytes')
PY
	rm -f "$out.raw"
elif [ "$what" = shim ]; then
	tr -d '\000' < "$out.raw" > "$out"
	rm -f "$out.raw"
	wc -c "$out"
else
	mv "$out.raw" "$out"
	ls -l "$out"
fi
