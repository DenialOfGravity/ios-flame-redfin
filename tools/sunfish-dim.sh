#!/bin/bash
# Screen brightness on the Pixel 4a, until the next boot: the MDP layer mixer (LM_0, which carries the whole
# 1080x2340 frame) blends the picture toward black with a constant alpha. On the OLED this saves power too.
#   tools/sunfish-dim.sh PERCENT      (1-100; 100 = as ABL left it)
# Registers: LM_0 at 0x0ae45000 (catalog 0x44000 + the MDP top's 0x1000), blend stages 0-3 CONST_ALPHA at
# +0x24/+0x3c/+0x54/+0x6c (foreground alpha in bits 23:16), CTL_0 FLUSH (0x0ae02018) bit 6 = LM_0.
# Needs /var/local/bin/pmem (phone/tools/pmem.c). Do not probe other MDP offsets: 0x0ae44000 hangs the bus.
set -e
cd "$(dirname "$0")/.."
p=${1:?percent}
[ "$p" -ge 1 ] && [ "$p" -le 100 ]
a=$(( (p * 255 + 50) / 100 ))
tools/sunfish-ssh "P=/var/local/bin/pmem; for o in 0x24 0x3c 0x54 0x6c; do \$P w \$((0x0ae45000 + o)) $(( a << 16 )) >/dev/null; done; \$P w 0x0ae02018 0x40 >/dev/null; \$P r 0x0ae45024 1"
echo "brightness ~${p}% (alpha $a)"
