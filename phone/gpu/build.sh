#!/bin/sh
# Build pmem and gpu for iOS 16 arm64 into phone/gpu/out (signed ad hoc).
set -e
cd "$(dirname "$0")"
CC=../../work/userland/bin/ios-cc
mkdir -p out
$CC -O2 -Wall -Wextra -Wno-unused-parameter -o out/pmem pmem_tool.c pmem.c
CORE=../../work/dxb/xnu/bsd/dev	# the kernel's A640 core, shared
$CC -O2 -Wall -Wextra -Wno-unused-parameter -I$CORE -o out/gpu gpu_tool.c gpu.c pmem.c $CORE/sweet_a6xx.c
for b in out/pmem out/gpu; do
	codesign -f -s - "$b" 2>/dev/null
	if nm -m "$b" | /usr/bin/grep -q "weak external"; then
		echo "$b: weak imports (iOS 16 may lack them):"; nm -m "$b" | /usr/bin/grep "weak external"
	fi
done
ls -la out
