#!/bin/sh
# Host unit tests of fastrpcd: argument layout bytes, the transport against a fake DSP, apps_std over a temp tree.
set -e
cd "$(dirname "$0")"
mkdir -p out
${CC:-cc} -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -fsanitize=address,undefined \
	-I. -Icompat -o out/test_fastrpcd test/test_fastrpcd.c transport.c apps_std.c listener.c localctl.c iobuffer.c \
	hexagonrpc.c error.c remotectl.c log.c interface/adsp_listener.c interface/apps_std.c -lpthread
./out/test_fastrpcd
