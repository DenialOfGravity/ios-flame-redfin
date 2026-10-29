#!/bin/sh
# Build SweetMetal2.bundle (metal2vulkan + Turnip) for iOS 16 arm64 into phone/metal2/out, signed ad hoc.
#   phone/metal2/build.sh        (first: tools/build-turnip-ios.sh, tools/build-m2v-bridge.sh)
# Also m2vtest (the bridge's self-test). Install: tools/flame-metal2-install.sh
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
CC="$ROOT/work/userland/bin/ios-cc"
BRIDGE=$ROOT/work/m2v-bridge/ios/libnative_metal_bridge.a
TURNIP=$ROOT/work/turnip/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib
B=out/SweetMetal2.bundle
rm -rf "$B" && mkdir -p "$B"
"$CC" -x objective-c++ -std=c++17 -fobjc-arc -O2 -g -Wall -Wno-deprecated-declarations -Wno-unused-function -bundle \
	-o "$B/SweetMetal2" SweetMetal2.mm NativeBridgeMetalFrontend.mm -x none "$BRIDGE" -Wl,-dead_strip -lc++ \
	-framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation 2>&1 |
	grep -v "was built for newer 'iOS' version" || true
[ -f "$B/SweetMetal2" ] || exit 1
rm -rf out/SweetMetal2.dSYM; mv "$B/SweetMetal2.dSYM" out/ 2>/dev/null || dsymutil "$B/SweetMetal2" -o out/SweetMetal2.dSYM 2>/dev/null || true
# unstripped copy (all local symbols) for tools-claude/sweet-prof.py --macho-dir .../syms
rm -rf out/syms && mkdir -p out/syms && cp "$B/SweetMetal2" out/syms/SweetMetal2
strip -x "$B/SweetMetal2"
cp Info.plist "$B/Info.plist"
cp "$TURNIP" "$B/libvulkan_freedreno.dylib"
strip -x "$B/libvulkan_freedreno.dylib"
codesign -f -s - "$B/libvulkan_freedreno.dylib" 2>/dev/null
codesign -f -s - "$B" 2>/dev/null
"$CC" -O2 -Wall -o out/m2vtest m2vtest.c "$BRIDGE" -Wl,-dead_strip 2>&1 | grep -v "was built for newer" || true
strip -x out/m2vtest && codesign -f -s - out/m2vtest 2>/dev/null
nm -m "$B/SweetMetal2" | grep "weak external" | grep -v "dynamically looked up" || true
ls -la "$B"
