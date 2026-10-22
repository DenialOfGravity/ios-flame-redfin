#!/bin/sh
# Build SweetMetal.bundle for iOS 16 arm64 into phone/metal/out (signed ad hoc).
set -e
cd "$(dirname "$0")"
B=out/SweetMetal.bundle
rm -rf "$B" && mkdir -p "$B"
../../work/userland/bin/ios-cc -O2 -Wall -fobjc-arc -bundle -o "$B/SweetMetal" SweetMetal.m a6draw.m sweetgpu.c \
	-framework Foundation -framework Metal -framework IOSurface -framework IOKit
cp Info.plist "$B/Info.plist"
# pipeline templates (tools/rdtemplate.py export of work/mesa/draw captures)
mkdir -p "$B/pipelines" && cp pipelines/*.json "$B/pipelines/" 2>/dev/null || true
codesign -f -s - "$B" 2>/dev/null
if nm -m "$B/SweetMetal" | /usr/bin/grep -q "weak external"; then nm -m "$B/SweetMetal" | /usr/bin/grep "weak external"; fi
ls -la "$B"
