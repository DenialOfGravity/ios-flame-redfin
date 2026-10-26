#!/bin/bash
# xnu.sh REPO OUT: the SWEET kernel (xnu-8796.141.3 + REPO/xnu/patches, DEVELOPMENT ARM64 SWEET) on Linux.
# The steps of .github/workflows/xnu.yml (blacktop/darwin-xnu-build build.sh at its pinned commit), with UniXNU's Linux
# toolchain (setup.sh xnu-tools) in place of Xcode: patched clang, cctools ld64, mig, iig-port, xcrun/plutil shims.
# State in $WORK/xnu: xnu/ (patched source; only files whose content changed are rewritten, so make is
# incremental like CI's cache), build/xnu.obj, fakeroot/ (headers, libfirehose_kernel, libcc_kext; made once).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
R=$1 OUT=$2
X=$WORK/xnu FR=$WORK/xnu/fakeroot
XNU_TAG=xnu-8796.141.3 MACOS_VERSION=13.5 RC_DARWIN_KERNEL_VERSION=22.6.0
KERNEL_CONFIG=DEVELOPMENT ARCH_CONFIG=ARM64 MACHINE_CONFIG=SWEET
DXB_REPO=https://github.com/blacktop/darwin-xnu-build DXB_SHA=663906528d1cd5ea8fde7de6f16de73db9511549
RELEASE_URL=https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-135/release.json
LLVM_COMMIT=58c46bae21181fb4240cf964461bea738d96d50e	# compiler-rt profile sources for libcc_kext (UniXNU's pin)
LIBC_COMMIT=899a3b2d52d95d75e05fb286a5e64975ec3de757	# Libc headers for the same
mkdir -p "$X" "$FR"
[ -x "$XNU_CLANG" ] || die "no $XNU_CLANG: run the agent's  build-setup xnu-tools  first"
[ -x "$CLT/bin/ld" ] && [ -x "$CLT/libexec/migcom" ] && [ -x "$XCT/bin/iig" ] || die "toolchain incomplete: build-setup xnu-tools"

# Linux xcrun/clang setup (UniXNU scripts/linux): xcrun -show-sdk-path = the fakeroot; clang = the patched clang for a
# plain arm64 Darwin kernel (SWEET is -march=armv8.2-a+crypto, no arm64e, no Apple CPU predefines).
export LB_MODE=xnu LB_TC=$TC UNIXNU_SDKROOT=$FR UNIXNU_SDK_VERSION=14.0 PLATFORM=MacOSX
export CROSS_CLANG=$XNU_CLANG DARWIN_TRIPLE=arm64-apple-macos14.0
# + diagnostics that clang 21+ makes errors by default and Xcode 15's clang (CI) only warns about
# -mcpu=generic: for an arm64-apple-macos triple upstream clang picks target-cpu apple-m1 whatever -march says, and the
# backend then uses M1-only instructions (RCPC2 stlur in firehose_buffer_stream_chunk_install, ldapr, udot, xpaclri):
# SM7250's Cortex-A76/A55 have no LRCPC2 -> undefined instruction early in boot (r29a, 2026-10-26). Apple clang (CI)
# gives the plain armv8.2-a+crypto of SWEET's MACHINE_FLAGS; generic + -march is the same feature set.
export CROSS_EXTRA_FLAGS="-mcpu=generic -mllvm -disable-atexit-based-global-dtor-lowering -Wno-error=incompatible-pointer-types"
export PATH="$TC/xnu-bin:$CLT/bin:$XCT/bin:$PATH"
ln -sf "$(command -v python3)" "$TC/xnu-bin/python"	# tools/lldbmacros scripts run `env python`

tag_of() {	# project -> its tag in macOS 13.5's release.json
	[ -s "$SRC/macos-135.json" ] || curl -fsSL "$RELEASE_URL" -o "$SRC/macos-135.json" || die "release.json"
	python3 -c "import json,sys;print([p['tag'] for p in json.load(open(sys.argv[1]))['projects'] if p['project']==sys.argv[2]][0])" "$SRC/macos-135.json" "$1"
}
apple() {	# project -> $SRC/<project>-<tag> (shallow clone at the 13.5 tag)
	local tag; tag=$(tag_of "$1") || exit 1
	local d=$SRC/$tag
	[ -d "$d/.git" ] || git clone -q --depth 1 --branch "$tag" "https://github.com/apple-oss-distributions/$1.git" "$d" || die "clone $1 $tag"
	echo "$d"
}

# ---- 1. patched source ----
PRISTINE=$(apple xnu)
[ "$(basename "$PRISTINE")" = "$XNU_TAG" ] || die "13.5's xnu is $(basename "$PRISTINE"), expected $XNU_TAG"
DXB=$SRC/dxb
[ "$(git -C "$DXB" rev-parse HEAD 2>/dev/null)" = "$DXB_SHA" ] || { rm -rf "$DXB"; git init -q "$DXB";
	git -C "$DXB" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA" && git -C "$DXB" checkout -q FETCH_HEAD; } || die "dxb"
PREP=$X/prep
rm -rf "$PREP"; mkdir -p "$PREP/patches"
cp -a "$PRISTINE" "$PREP/xnu"
cp "$DXB"/patches/*.patch "$R"/xnu/patches/*.patch "$R"/xnu/patches/*.sh "$PREP/patches/" 2>/dev/null
say "patching: $(ls "$PREP/patches" | wc -l) files"
(
	cd "$PREP/xnu" || exit 1
	# blacktop's patches() seds (GNU sed). MIG/MIGCOM are passed to make instead of its `find $(FAKEROOT_DIR)` rewrite.
	sed -i 's|^AVAILABILITY_PL="${SDKROOT}/${DRIVERKITROOT}|AVAILABILITY_PL="${FAKEROOT_DIR}|g' bsd/sys/make_symbol_aliasing.sh
	sed -i 's|^#include.*BSD.xcconfig.*||g' libsyscall/Libsyscall.xcconfig
	sed -i 's|^LDFLAGS_KERNEL_SDK	= -L$(SDKROOT).*|LDFLAGS_KERNEL_SDK	= -L$(FAKEROOT_DIR)/usr/local/lib/kernel -lfirehose_kernel|g' makedefs/MakeInc.def
	sed -i 's|^\(INCFLAGS_SDK[[:space:]]*=\) -I$(SDKROOT)/usr/local/include/\(kernel\)\{0,1\}|\1 -I$(FAKEROOT_DIR)/usr/local/include/kernel|' makedefs/MakeInc.def
	export LC_ALL=C MACOS_VERSION MACHINE_CONFIG KDKROOT=$X/fake-kdk
	for s in ../patches/*.sh; do
		say "script $(basename "$s")"
		# their xcrun --sdk macosx must give the real macOS SDK (TargetConditionals.h), not the fakeroot
		LB_MODE= PATH="$LBIN:$PATH" bash "$s" || exit 1
	done
	for p in ../patches/*.patch; do
		if c=$(git apply --check "$p" 2>&1); then git apply "$p" || exit 1
		else echo "skip $(basename "$p"): $(echo "$c" | head -1)"; fi
	done
	# UniXNU scripts/linux/prepare-xnu.py "source": sources that assume Apple's clang or BSD tools
	python3 - <<'PY'
from pathlib import Path
s = Path('bsd/kern/makesyscalls.sh'); t = s.read_text()
if '\\(sy_call_t *\\)' in t: s.write_text(t.replace('\\(sy_call_t *\\)', '(sy_call_t *)')); print('linux: makesyscalls.sh mawk escape')
s = Path('osfmk/arm64/corecrypto/arm64_isa_compatibility.h')
old = '#if defined(__clang__) && ((defined(__apple_build_version__) && __apple_build_version__ > 5010000))\n'
if s.exists() and old in s.read_text():
    s.write_text(s.read_text().replace(old, '#if defined(__clang__) && (!defined(__apple_build_version__) || __apple_build_version__ > 5010000)\n')); print('linux: arm64_isa_compatibility.h')
s = Path('SETUP/kextsymboltool/kextsymboltool.c'); t = s.read_text()
old = '''	if (offset != lseek(fd, offset, SEEK_SET)) {
		err = kErrorDiskFull;
	} else {
		err = kErrorNone;
	}
'''
new = '''	if (offset != lseek(fd, offset, SEEK_SET)) {
		struct stat st;
		/* Linux lseek() returns 0 on /dev/null (check_all_exports): not an error */
		if (0 == fstat(fd, &st) && S_ISCHR(st.st_mode)) {
			return kErrorNone;
		}
		err = kErrorDiskFull;
	} else {
		err = kErrorNone;
	}
'''
if 'S_ISCHR' not in t and t.count(old) == 1:
    t = t.replace(old, new)
    if '#include <sys/stat.h>' not in t: t = t.replace('#include <sys/types.h>', '#include <sys/types.h>\n#include <sys/stat.h>', 1)
    s.write_text(t); print('linux: kextsymboltool lseek')
# Apple clang only warns (-Wvoid-ptr-dereference) about *(void *) inside __typeof__ in C++ (IOFreeType(void *mem, T) in
# IOOverrideTypedOperators); upstream clang errors. Same check, written with clang's __remove_pointer in C++.
s = Path('osfmk/kern/kalloc.h'); t = s.read_text()
old = """	(__builtin_xnu_types_compatible(__typeof__(*(ptr)), type) ||   \\
	    __builtin_xnu_types_compatible(__typeof__(*(ptr)), void))  \\
"""
new = """	(__builtin_xnu_types_compatible(__KT_PTR_ELEM_T(ptr), type) ||   \\
	    __builtin_xnu_types_compatible(__KT_PTR_ELEM_T(ptr), void))  \\
"""
defs = """#ifdef __cplusplus
#define __KT_PTR_ELEM_T(ptr) __remove_pointer(__typeof__(ptr))
#else
#define __KT_PTR_ELEM_T(ptr) __typeof__(*(ptr))
#endif
#define KALLOC_TYPE_IS_COMPATIBLE_PTR(ptr, type)"""
if old in t:
    t = t.replace(old, new).replace('#define KALLOC_TYPE_IS_COMPATIBLE_PTR(ptr, type)', defs, 1)
    s.write_text(t); print('linux: kalloc.h KALLOC_TYPE_IS_COMPATIBLE_PTR for C++')
else:
    print('linux: kalloc.h pattern not found (changed upstream?)')
PY
) || die "patching failed"
mkdir -p "$X/xnu"
say "sync into $X/xnu (changed files only):"
rsync -rlc --no-times --delete --exclude .git --itemize-changes "$PREP/xnu/" "$X/xnu/" | grep -v '^\.' | head -60 || true
if [ "${XNU_CLEAN:-0}" = 1 ]; then rm -rf "$X/build"; fi
rm -rf "$X"/build/xnu.obj/kernel.* "$FR"/System/Library/Kernels/kernel.*

# Compiler or flags changed since the last build -> make does not notice: rebuild every object and the two libraries
FLAGS_ID="$(sha1sum < "$XNU_CLANG" | cut -c1-12) $DARWIN_TRIPLE $CROSS_EXTRA_FLAGS $(sha1sum < "$CLT/bin/clang" | cut -c1-12)"
if [ "$(cat "$X/build/.lb-flags" 2>/dev/null)" != "$FLAGS_ID" ]; then
	say "compiler/flags changed: full rebuild ($FLAGS_ID)"
	rm -rf "$X/build/xnu.obj" "$X/build/xnu.sym" "$X/build/firehose" "$SRC/linux-cc_kext/obj" \
		"$FR/usr/local/lib/kernel/libfirehose_kernel.a" "$FR/usr/local/lib/kernel/libcc_kext.a"
	mkdir -p "$X/build"; echo "$FLAGS_ID" > "$X/build/.lb-flags"
fi

# ---- 2. fakeroot (once) ----
MEM=$(( $(getconf _PHYS_PAGES) * $(getconf PAGE_SIZE) ))
LINUX_ARGS=(XCRUN="$TC/xnu-bin/xcrun" PLUTIL="$TC/xnu-bin/plutil" HOST_CODESIGN="$TC/xnu-bin/codesign"
	HOST_CC="$CLT/bin/xnu-host-cc" MIG="$CLT/bin/mig" MIGCOM="$CLT/libexec/migcom" TIGHTBEAMC=tightbeamc-not-supported
	BUILD_DSYM=0 MEMORY_SIZE=$MEM SYSCTL_HW_PHYSICALCPU=$JOBS SYSCTL_HW_LOGICALCPU=$JOBS KERNEL_BUILDS_IN_PARALLEL=1
	RC_DARWIN_KERNEL_VERSION=$RC_DARWIN_KERNEL_VERSION FAKEROOT_DIR="$FR" KDKROOT="$X/fake-kdk")
mkdir -p "$X/fake-kdk" "$FR/usr/include" "$FR/usr/local/lib/kernel" "$FR/usr/local/include/kernel/os"
cp "$MAC_SDK/usr/include/TargetConditionals.h" "$FR/usr/include/" 2>/dev/null || cp "$TC/TargetConditionals.h" "$FR/usr/include/"
if [ ! -x "$FR/usr/local/libexec/availability.pl" ] || [ ! -f "$FR/usr/local/include/dyld/VersionMap.h" ]; then
	say "fakeroot: AvailabilityVersions"
	AV=$(apple AvailabilityVersions)
	rm -f "$FR/System/Library/Frameworks/Kernel.framework/Versions/A/Headers/AvailabilityVersions.h"	# its ln has no -f
	make -C "$AV" install -j"$JOBS" OBJROOT="$X/build/availability" SYMROOT="$X/build/availability" DSTROOT="$FR" \
		CMAKE="$(command -v cmake)" NINJA="$(command -v ninja)" || die "AvailabilityVersions (needs ruby: build-apt)"
fi
if [ ! -f "$FR/.xnu-headers" ]; then
	say "fakeroot: xnu headers"
	( cd "$X/xnu" && make installhdrs SDKROOT=macosx ARCH_CONFIGS=ARM64 OBJROOT="$X/build/xnu-hdrs.obj" \
		SYMROOT="$X/build/xnu-hdrs.sym" DSTROOT="$FR" "${LINUX_ARGS[@]}" ) || die "installhdrs"
	touch "$FR/.xnu-headers"
fi
if [ ! -f "$FR/usr/local/include/_simple.h" ]; then
	say "fakeroot: libplatform headers"
	LP=$(apple libplatform)
	cp -R "$LP/include/." "$LP/private/." "$FR/usr/local/include/"
	mkdir -p "$FR/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform"
	cp -R "$LP/private/platform/." "$FR/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform/"
fi
if [ ! -f "$FR/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
	say "fakeroot: libfirehose_kernel (libdispatch's xcconfig, without Xcode)"
	LD_=$(apple libdispatch)
	mkdir -p "$FR/usr/local/include/os"
	for h in "$LD_"/os/*.h; do unifdef -DKERNEL=1 -DOS_FIREHOSE_SPI=1 -DOS_VOUCHER_ACTIVITY_SPI_TYPES=1 -UOS_VOUCHER_ACTIVITY_SPI \
		-o "$FR/usr/local/include/os/$(basename "$h")" "$h"; done
	unifdef -DKERNEL=1 -DOS_FIREHOSE_SPI=1 -DOS_VOUCHER_ACTIVITY_SPI_TYPES=1 -UOS_VOUCHER_ACTIVITY_SPI \
		-o "$FR/usr/local/include/kernel/os/firehose_buffer_private.h" "$LD_/os/firehose_buffer_private.h"
	mkdir -p "$X/build/firehose"
	xcrun clang -std=gnu11 -Os -g -mkernel -nostdinc -Wno-packed -DKERNEL=1 -DDISPATCH_USE_DTRACE=0 \
		-DOS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1 -DOS_ATOMIC_CONFIG_STARVATION_FREE_ONLY=0 \
		-I"$LD_" -I"$FR/System/Library/Frameworks/Kernel.framework/PrivateHeaders" \
		-I"$FR/System/Library/Frameworks/Kernel.framework/Headers" -I"$FR/usr/local/include/os" \
		-I"$FR/usr/local/include/firehose" -I"$FR/usr/include" -I"$FR/usr/local/include" -I"$X/xnu/EXTERNAL_HEADERS" \
		-c "$LD_/src/firehose/firehose_buffer.c" -o "$X/build/firehose/firehose_buffer.o" || die "firehose_buffer.c"
	xcrun libtool -static -o "$FR/usr/local/lib/kernel/libfirehose_kernel.a" "$X/build/firehose/firehose_buffer.o" || die libtool
fi
if [ ! -f "$FR/usr/local/lib/kernel/libcc_kext.a" ]; then
	say "fakeroot: libcc_kext.a (compiler-rt profile runtime; Apple clang ships it)"
	L=$SRC/linux-cc_kext; mkdir -p "$L/obj"
	for spec in "llvm-project https://github.com/llvm/llvm-project $LLVM_COMMIT compiler-rt/lib/profile compiler-rt/include/profile" \
	            "Libc https://github.com/apple-oss-distributions/Libc.git $LIBC_COMMIT include"; do
		set -- $spec; d=$L/$1
		[ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$3" ] && continue
		rm -rf "$d"; git init -q "$d"; git -C "$d" sparse-checkout set --no-cone "${@:4}"
		git -C "$d" fetch -q --depth 1 --filter=blob:none "$2" "$3" && git -C "$d" checkout -q FETCH_HEAD || die "fetch $1"
	done
	objs=()
	for n in InstrProfiling InstrProfilingBuffer InstrProfilingPlatformDarwin InstrProfilingWriter InstrProfilingInternal InstrProfilingVersionVar; do
		xcrun clang -isysroot "$FR" -mkernel -DKERNEL_USE -O3 -fPIC -w -I "$L/llvm-project/compiler-rt/include" \
			-I "$FR/System/Library/Frameworks/Kernel.framework/Headers" -idirafter "$L/Libc/include" \
			-idirafter "$X/xnu/libsyscall/wrappers" -idirafter "$MAC_SDK/usr/include" -c "$L/llvm-project/compiler-rt/lib/profile/$n.c" -o "$L/obj/$n.o" || die "cc_kext $n"
		objs+=("$L/obj/$n.o")
	done
	xcrun libtool -static -o "$FR/usr/local/lib/kernel/libcc_kext.a" "${objs[@]}" || die libtool
fi

# ---- 3. the kernel ----
export KERNEL_BUILD_DATE=${KERNEL_BUILD_DATE:-$(TZ=UTC git -C "$PRISTINE" log -1 --format=%cd --date=format-local:'%a %b %e %T %Z %Y')}
export KERNEL_BUILD_OBJROOT=$XNU_TAG
KEEP=-k; [ "${XNU_KEEP_GOING:-1}" = 0 ] && KEEP=
say "make install ($JOBS jobs) -> $X/build/build.log"
( cd "$X/xnu" && make install -j"$JOBS" -Otarget $KEEP VERBOSE=YES SDKROOT=macosx \
	TARGET_CONFIGS="$KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG" CONCISE=0 LOGCOLORS=n BUILD_WERROR=0 BUILD_LTO=0 \
	SRCROOT="$X/xnu" OBJROOT="$X/build/xnu.obj" SYMROOT="$X/build/xnu.sym" DSTROOT="$FR" \
	LD_KERNEL_LIBS="$FR/usr/local/lib/kernel/libcc_kext.a" "${LINUX_ARGS[@]}" ) > "$X/build/build.log" 2>&1
rc=$?
grep -a -n -E 'error:|error generated|errors generated|\*\*\* \[' "$X/build/build.log" | head -300 > "$OUT/errors.txt"
grep -a -n -B3 -A12 -E ' error:' "$X/build/build.log" | head -1500 > "$OUT/errors-context.txt"
tail -300 "$X/build/build.log" > "$OUT/tail.txt"
gzip -9 -c "$X/build/build.log" > "$OUT/make.log.gz"
K=$FR/System/Library/Kernels/kernel.development.sweet
if [ $rc = 0 ] && [ -f "$K" ]; then
	gzip -9 -c "$K" > "$OUT/kernel.development.sweet.gz"
	(cd "$(dirname "$K")" && sha256sum kernel.development.sweet) > "$OUT/SHA256SUMS"
	rm -f "$OUT/errors.txt" "$OUT/errors-context.txt"
	echo "$FLAGS_ID" > "$OUT/COMPILER.txt"
	# ISA check: SM7250 is Cortex-A76/A55 (armv8.2 + RCpc + DotProd). Instructions of later architectures = no boot.
	bad=$(llvm-objdump -d --no-show-raw-insn --no-leading-addr "$K" | awk -F'\t' '/^ +\t/{split($2,m,".");print m[1]}' |
		grep -c -x -E 'stlur[bh]?|ldapur(s?[bhw])?|cfinv|setf8|setf16|rmif|axflag|xaflag|frint(32|64)[xz]|sb|bcax|eor3|rax1|xar|sha512(h|h2|su0|su1)|sm3.*|sm4.*|bfcvtn?2?|bfdot|bfmmla|bfmlal[bt]|[su]s?mmla|usdot|sudot|ld64b|st64bv?0?')
	if [ "$bad" != 0 ]; then say "ISA CHECK FAILED: $bad instructions newer than armv8.2+RCpc+DotProd (see COMPILER.txt)"; exit 1; fi
	say "ISA check ok (no armv8.4+ instructions)"
	# the agent's `klog PA` for this kernel: PA = VA(_sweet_log_total) - 0xfffffe0006000000 + 0x100000000
	va=$(llvm-nm "$K" | awk '$3=="_sweet_log_total"{print $1}')
	[ -n "$va" ] && python3 -c "import sys;print('klog PA 0x%x  (_sweet_log_total 0x%s)'%(int(sys.argv[1],16)-0xfffffe0006000000+0x100000000,sys.argv[1]))" "$va" | tee "$OUT/KLOG_PA.txt"
	cat "$OUT/SHA256SUMS"; ls -la "$OUT"
	say "kernel ok: ${OUT}/kernel.development.sweet.gz"
else
	say "make failed (rc $rc); first errors:"; head -40 "$OUT/errors.txt"; exit 1
fi
