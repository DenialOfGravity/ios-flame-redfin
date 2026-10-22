#!/bin/bash
# Build FlameBridge.app (flamebridge.c) and sign it ad hoc. macOS asks once for Local Network access;
# a rebuild changes the signature and may ask again, so change ports.txt instead of rebuilding.
#   tools/flamebridge/build.sh && open tools/flamebridge/FlameBridge.app
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p FlameBridge.app/Contents/MacOS
clang -O2 -Wall -o FlameBridge.app/Contents/MacOS/FlameBridge flamebridge.c
codesign -f -s - FlameBridge.app
