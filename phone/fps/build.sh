#!/bin/sh
# Build SweetFPS.dylib (iOS 16 arm64, signed ad hoc) into phone/fps/out (ws-u-fps; see SweetFPS.m).
# Install: files put out/SweetFPS.dylib /var/local/lib/SweetFPS.dylib (0644), then give SpringBoard
# DYLD_INSERT_LIBRARIES=/var/local/lib/SweetFPS.dylib and SWEET_FPS=MODE (launchd EnvironmentVariables) and restart it.
set -e
cd "$(dirname "$0")"
mkdir -p out
../../work/userland/bin/ios-cc -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -dynamiclib \
	-install_name /var/local/lib/SweetFPS.dylib \
	-framework Foundation -framework QuartzCore \
	-o out/SweetFPS.dylib SweetFPS.m
codesign -f -s - out/SweetFPS.dylib
ls -la out/SweetFPS.dylib
# The PC's local userland builder has a fixed component list (it runs phone/haptics/build.sh, which calls this):
# the dylib goes into the build log as base64 between these markers (tools-claude: sed -n '/^SWEETFPS-B64-BEGIN/,/^SWEETFPS-B64-END/p').
if [ -n "${SWEETFPS_B64:-}" ]; then
	echo SWEETFPS-B64-BEGIN
	base64 < out/SweetFPS.dylib
	echo SWEETFPS-B64-END
fi
