#!/bin/sh
# Build btd for iOS 16 arm64 into phone/bt/out (signed ad hoc). First the host test (tlv_test.c: TLV
# segmenter, NVM edits, the whole bring-up against a fake controller) with the build machine's cc.
# Install: python3 tools/flame-files.py put phone/bt/out/btd /var/local/bin/btd 755
# Firmware (vendor files, never in git): /vendor/firmware/crbtfw32.tlv, crnv32.bin, crnv32u.bin from the
# phone's Android -> /private/var/local/fw/ on iOS.
set -e
cd "$(dirname "$0")"
mkdir -p out
HOSTFW=
[ "$(uname)" = Darwin ] && HOSTFW="-framework IOKit -framework CoreFoundation"
cc -O1 -Wall -DBTD_TEST -o out/tlv_test tlv_test.c tlv.c hci.c qca.c btd.c $HOSTFW
if ! ./out/tlv_test > out/tlv_test.log 2>&1; then
	grep -v '^\[' out/tlv_test.log | tail -30
	exit 1
fi
grep -v '^\[' out/tlv_test.log | tail -8
../../work/userland/bin/ios-cc -O2 -Wall -Wextra -Wno-unused-parameter -I../wifi -o out/btd \
	btd.c hci.c qca.c tlv.c geni.c power.c uart_dev.c ../wifi/pmem.c -framework IOKit -framework CoreFoundation
codesign -f -s - out/btd 2>/dev/null
ls -la out/btd
# BlueTool stand-in (bluetool.c): /var/local/bin/bluetool, the com.apple.BlueTool job pointed at it
../../work/userland/bin/ios-cc -O2 -Wall -Wextra -Wno-unused-parameter -o out/bluetool bluetool.c
codesign -f -s - out/bluetool 2>/dev/null
ls -la out/bluetool
