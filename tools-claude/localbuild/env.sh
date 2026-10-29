# Sourced by setup.sh and build.sh: where everything lives on the build host.
BR=${BR:-$HOME/redfin-build}          # all local build state (ext4, not /mnt/c: much faster)
TC=$BR/toolchain                      # toolchain prefix (UniXNU layout: CommandLineTools/usr, XcodeDefault.xctoolchain/usr)
SRC=$BR/src                           # source checkouts (the repo, UniXNU, Apple OSS, Mesa, ...)
WORK=$BR/work                         # per-target build trees
CLT=$TC/CommandLineTools/usr
XCT=$TC/XcodeDefault.xctoolchain/usr
LBIN=$TC/lb-bin                       # our wrappers (xcrun, codesign, plutil, nm, strip, ios-cc, ...), from localbuild/bin
JOBS=${JOBS:-$(nproc)}
REPO_URL=https://github.com/DenialOfGravity/ios-flame-redfin.git
UNIXNU_URL=https://github.com/UniXNU/UniXNU.git
UNIXNU_COMMIT=ae687009348296e97e49ce6e925795044f363ce6   # scripts/linux (BSD-2-Clause-Patent), 2026-10-26
# Apple SDKs from xtool (Xcode .xip extracted by `xtool setup`)
_PLAT=$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms
IOS_SDK=${IOS_SDK:-$(ls -d "$_PLAT"/iPhoneOS.platform/Developer/SDKs/iPhoneOS[0-9]*.sdk 2>/dev/null | sort -V | tail -1)}
MAC_SDK=${MAC_SDK:-$(ls -d "$_PLAT"/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -V | tail -1)}
# The clang that has __builtin_xnu_type_* (xnu-8796's kalloc_type needs them): ours, built by `setup llvm`
XNU_CLANG=${XNU_CLANG:-$TC/llvm/bin/clang}
export PATH="$TC/bin:$HOME/.cargo/bin:$PATH" LB_TC=$TC
mkdir -p "$BR" "$SRC" "$WORK"
say() { echo "[$(date +%T)] $*"; }
die() { echo "[$(date +%T)] ERROR: $*" >&2; exit 1; }
