#!/bin/sh
# Build vktest (Turnip smoke test) for the phone into phone/turnip/out, plus a signed copy of Turnip.
#   phone/turnip/build.sh        (Turnip itself: tools/build-turnip-ios.sh)
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
mkdir -p out
: > out/shaders.h
for s in fill.comp:fill_comp tri.vert:tri_vert tri.frag:tri_frag full.vert:full_vert alu.frag:alu_frag alu16.frag:alu16_frag; do
	glslangValidator -V --target-env vulkan1.2 --vn "${s#*:}" -o out/"${s#*:}".h shaders/"${s%%:*}" >/dev/null
	cat out/"${s#*:}".h >> out/shaders.h
done
"$ROOT/work/userland/bin/ios-cc" -O2 -Wall -I out -I "$ROOT/work/turnip/mesa/include" -o out/vktest vktest.c
codesign -f -s - out/vktest 2>/dev/null
# u-gpudraw: into the metal2 build's outputs too (lb.sh copies phone/metal2/out)
[ -d ../metal2/out ] && cp out/vktest ../metal2/out/vktest
cp "$ROOT/work/turnip/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib" out/
codesign -f -s - out/libvulkan_freedreno.dylib 2>/dev/null
ls -la out/vktest out/libvulkan_freedreno.dylib
