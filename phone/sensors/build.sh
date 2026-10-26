#!/bin/sh
# Build sensd for iOS 16 arm64 into phone/sensors/out (signed ad hoc). Host tests: sh phone/sensors/test.sh
set -e
cd "$(dirname "$0")"
mkdir -p out
../../work/userland/bin/ios-cc -O2 -Wall -Wextra -Wno-unused-parameter -o out/sensd \
	sensd.c sensor.c sns.c pb.c rqrtr.c ../wifi/qmi.c
codesign -f -s - --entitlements sensd-ents.plist out/sensd 2>/dev/null || codesign -f -s - out/sensd
ls -la out/sensd
