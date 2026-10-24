#!/bin/sh
# Build SweetHaptics.dylib (iOS 16 arm64, signed ad hoc) into phone/haptics/out.
# Install: python3 tools/flame-files.py put phone/haptics/out/SweetHaptics.dylib /var/local/lib/SweetHaptics.dylib 644
# then boot with sweetui=1 (xnu 0912).
set -e
cd "$(dirname "$0")"
mkdir -p out
../../work/userland/bin/ios-cc -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -dynamiclib \
	-install_name /var/local/lib/SweetHaptics.dylib \
	-framework Foundation -framework UIKit -framework AudioToolbox \
	-o out/SweetHaptics.dylib SweetHaptics.m
codesign -f -s - out/SweetHaptics.dylib
ls -la out/SweetHaptics.dylib
