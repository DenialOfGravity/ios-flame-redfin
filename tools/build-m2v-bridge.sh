#!/bin/sh
# Build the native Metal bridge (phone/metal2/bridge/NativeMetalBridge.rs: UniXNU's bridge over the metal2vulkan
# runtime, MIT) as a static library for iOS 16 arm64.
#   tools/build-m2v-bridge.sh [host]
# Source: work/metal2vulkan = github.com/steelbrain/metal2vulkan at M2V_COMMIT of .github/workflows/metal2.yml (f6a96b7d on
# ws-u-m2vup; 720ef1ce, UniXNU's pin, before) + phone/metal2/bridge/patches/*.patch (the 720ef1ce series: patches/pin-720ef1ce).
# Output: work/m2v-bridge/<target>/libnative_metal_bridge.a
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD
SRC=$ROOT/work/metal2vulkan
OUT=$ROOT/work/m2v-bridge
target=${1:-ios}
mkdir -p "$OUT"
LLVM_AS=/opt/homebrew/opt/llvm/bin/llvm-as
"$LLVM_AS" -o "$OUT/runtime_examples.air" "$SRC/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll"
"$LLVM_AS" -o "$OUT/function_constant.air" "$SRC/crates/metal2vulkan-validation/fixtures/public/kernel_function_constant_gate_fold.ll"
cat > "$OUT/Cargo.toml" <<EOF
[package]
name = "native-metal-bridge"
version = "0.1.0"
edition = "2024"
rust-version = "1.98"
[workspace]
[lib]
crate-type = ["staticlib"]
path = "$ROOT/phone/metal2/bridge/NativeMetalBridge.rs"
[dependencies]
metal2vulkan = { path = "$SRC/crates/metal2vulkan", features = ["ash"] }
metal2vulkan-runtime = { path = "$SRC/crates/metal2vulkan-runtime" }
libc = "0.2"
sha2 = { version = "0.10", features = ["asm"] }
[profile.release]
panic = "unwind"
debug = 1
EOF
if [ "$target" = ios ]; then triple=aarch64-apple-ios; else triple=aarch64-apple-darwin; fi
NMB_FIXTURE_AIR=$OUT/runtime_examples.air NMB_FC_AIR=$OUT/function_constant.air IPHONEOS_DEPLOYMENT_TARGET=16.0 \
	MACOSX_DEPLOYMENT_TARGET=14.0 cargo +1.98.0 build --release --manifest-path "$OUT/Cargo.toml" --target $triple \
	--target-dir "$OUT/target" > "$OUT/build-$target.log" 2>&1 || { grep -E "^(error|warning: unused)" -A6 "$OUT/build-$target.log" | head -60; exit 1; }
mkdir -p "$OUT/$target"
cp "$OUT/target/$triple/release/libnative_metal_bridge.a" "$OUT/$target/"
ls -la "$OUT/$target/libnative_metal_bridge.a"
