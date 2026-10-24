#!/bin/bash
# Metal-client env experiment: write /var/local/mtl2-env (KEY=VALUE args, none = empty), restart backboardd
# (and with it SpringBoard), then tools/sunfish-fpsbench.sh (BENCH_TIGHT=1) and backboardd's GPU ms per frame.
#   tools/sunfish-m2env-bench.sh TAG [KEY=VALUE...]
cd "$(dirname "$0")/.." || exit 1
tag=$1; shift
ssh_() { timeout 20 tools/sunfish-ssh "$@"; }
ssh_ "rm -f /var/local/mtl2-tu-debug; [ -n \"${TUDBG:-}\" ] && echo ${TUDBG:-} > /var/local/mtl2-tu-debug; : > /var/local/mtl2-env; for kv in $*; do echo \$kv >> /var/local/mtl2-env; done
	p=\$(psx | grep ' backboardd\$' | sed 's/^ *//' | cut -d' ' -f1); kill \$p" || exit 1
sleep 35
BENCH_TIGHT=1 tools/sunfish-fpsbench.sh "$tag" 20
sed -n "/=== bench $tag start/,/=== bench $tag end/p" ../logs/usb-live.log | grep -a 'SWEET GPU: 5s' |
	grep -oE 'GPU busy [0-9]+ ms \([0-9]+%\)|backboardd [0-9]+/[0-9]+ms' | paste -d' ' - - | head -4
