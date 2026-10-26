#!/bin/sh
# Build fastrpcd (the ADSP sensors PD's file service) for iOS 16 arm64 into phone/fastrpc/out (signed ad hoc).
# GPL-3.0-or-later: a separate program (hexagonrpcd's code, see LICENSE.hexagonrpc). Host tests: sh test.sh
set -e
cd "$(dirname "$0")"
mkdir -p out
SRC="fastrpcd.c transport.c apps_std.c apps_mem.c listener.c localctl.c iobuffer.c hexagonrpc.c handle.c error.c
	remotectl.c log.c interface/adsp_default_listener.c interface/adsp_listener.c interface/apps_mem.c
	interface/apps_std.c"
${IOS_CC:-../../work/userland/bin/ios-cc} -O2 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
	-I. -Icompat -o out/fastrpcd $SRC -lpthread
codesign -f -s - out/fastrpcd 2>/dev/null || true
ls -la out/fastrpcd
