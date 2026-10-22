#!/opt/homebrew/bin/bash
# Incremental XNU build in work/dxb, after one full run of blacktop's build.sh
# (which clones xnu-8796.141.3, applies xnu/patches and builds mig, ctf tools,
# libfirehose_kernel and the headers into work/dxb/fakeroot).
#
#   tools/build-xnu.sh [LOG]      -> work/dxb/build/xnu.obj/kernel.development.sweet
#
# Same make invocation as build.sh's build_xnu, with Xcode's toolchain first
# in PATH. KDKROOT points at an empty directory: the SWEET config links no
# closed KDK libraries.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DXB=$ROOT/work/dxb
LOG=${1:-$ROOT/work/build-xnu.log}

export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
export PATH="$ROOT/work/bin:$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export CC=$(xcrun -find clang) CXX=$(xcrun -find clang++) LD=$(xcrun -find ld)
export AR=$(xcrun -find ar) RANLIB=$(xcrun -find ranlib) STRIP=$(xcrun -find strip) LIBTOOL=$(xcrun -find libtool)
export KERNEL_BUILD_DATE=${KERNEL_BUILD_DATE:-$(TZ=UTC git -C "$DXB/xnu" log -1 --format=%cd --date=format-local:'%a %b %e %T %Z %Y')}
export KERNEL_BUILD_OBJROOT=${KERNEL_BUILD_OBJROOT:-xnu-8796.141.3}
mkdir -p "$ROOT/work/fake-kdk"
NCPU=$(sysctl -n hw.ncpu)

cd "$DXB/xnu"
set +e
make install -j"$NCPU" -k VERBOSE=YES \
	CTFCONVERT="$DXB/fakeroot/usr/local/bin/ctfconvert" \
	CTFMERGE="$DXB/fakeroot/usr/local/bin/ctfmerge" \
	CTFDUMP="$DXB/fakeroot/usr/local/bin/ctfdump" \
	SDKROOT=macosx TARGET_CONFIGS="DEVELOPMENT ARM64 SWEET" CONCISE=0 LOGCOLORS=n \
	BUILD_WERROR=0 BUILD_LTO=0 SRCROOT="$DXB/xnu" OBJROOT="$DXB/build/xnu.obj" \
	SYMROOT="$DXB/build/xnu.sym" DSTROOT="$DXB/fakeroot" FAKEROOT_DIR="$DXB/fakeroot" \
	KDKROOT="$ROOT/work/fake-kdk" TIGHTBEAMC=tightbeamc-not-supported \
	RC_DARWIN_KERNEL_VERSION=22.6.0 MEMORY_SIZE=$(sysctl -n hw.memsize) \
	SYSCTL_HW_PHYSICALCPU="$NCPU" SYSCTL_HW_LOGICALCPU="$NCPU" KERNEL_BUILDS_IN_PARALLEL=1 \
	> "$LOG" 2>&1
rc=$?
set -e
grep -a -o -E '[A-Za-z0-9_./+-]+:[0-9]+:[0-9]+: (fatal )?error: .*' "$LOG" | sort -u | head -40 || true
K=$DXB/build/xnu.obj/kernel.development.sweet
if [ $rc -eq 0 ] && [ -f "$K" ]; then
	ls -la "$K"
	shasum -a 256 "$K"
else
	echo "build failed (make rc=$rc), log: $LOG" >&2
	exit 1
fi
