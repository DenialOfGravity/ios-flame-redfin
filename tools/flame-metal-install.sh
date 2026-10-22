#!/bin/bash
# Install SweetMetal.bundle (phone/metal, built with phone/metal/build.sh) into
# /System/Library/Extensions of the running iOS, then sync. Metal loads it at the next
# boot with boot-arg sweetmtl=1 (iokit/Kernel/arm/SweetAccelerator.cpp).
set -euo pipefail
cd "$(dirname "$0")/.."
phone/metal/build.sh >/dev/null
F="python3 tools/flame-files.py"
B=phone/metal/out/SweetMetal.bundle
D=/System/Library/Extensions/SweetMetal.bundle
$F mkdir $D 755 >/dev/null
$F mkdir $D/_CodeSignature 755 >/dev/null
$F put $B/SweetMetal $D/SweetMetal 755
$F put $B/Info.plist $D/Info.plist 644
$F put $B/_CodeSignature/CodeResources $D/_CodeSignature/CodeResources 644
python3 tools/flame-cmd.py sync >/dev/null 2>&1 || true
