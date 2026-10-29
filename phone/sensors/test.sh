#!/bin/sh
# Host unit tests of sensd's protobuf coder, SEE encoders/decoders and a canned SUID/stream exchange.
set -e
cd "$(dirname "$0")"
mkdir -p out
${CC:-cc} -O1 -g -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -o out/test_sensd \
	test_sensd.c pb.c sns.c sensor.c rqrtr.c ../wifi/qmi.c -lm
./out/test_sensd
