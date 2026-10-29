#!/bin/bash
# Local builds: the same steps as .github/workflows/{shim,userland,metal2,xnu}.yml, on Linux.
#   build.sh TARGET [REF]       TARGET shim | userland | metal2 | xnu;  REF branch or commit (default redfin-qol)
# Source: REF of DenialOfGravity/ios-flame-redfin, fetched fresh each run into $WORK/TARGET/repo (the build trees
# beside it are kept, so rebuilds are incremental). Result: $P/builds/TARGET/<REF>-<sha>/ (+ BUILD.txt, build.log).
# Env: XNU_CLEAN=1 (xnu: ignore the incremental tree), XNU_KEEP_GOING=0 (stop at the first error), JOBS=N.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
P=${P:-/mnt/c/ClaudeProjects/iOS_Pixel5}
T=${1:?target}; REF=${2:-redfin-qol}
TW=$WORK/$T; R=$TW/repo
mkdir -p "$TW"
exec 9>"$TW.lock"; flock -w 1800 9 || die "another $T build is still running"	# one build per target at a time (queue)
START=$(date +%s)

# ---- source at REF ----
MIRROR=$SRC/ios-redfin.git
[ -d "$MIRROR" ] || git init -q --bare "$MIRROR"
git -C "$MIRROR" fetch -q "$REPO_URL" "+$REF:refs/lb/$T" || die "cannot fetch $REF"	# per target: parallel builds
SHA=$(git -C "$MIRROR" rev-parse "refs/lb/$T")
[ -d "$R/.git" ] || git clone -q --shared --no-checkout "$MIRROR" "$R"
git -C "$R" fetch -q "$MIRROR" "$SHA" && git -C "$R" checkout -q -f "$SHA" && git -C "$R" clean -fdxq -e work/ || die "checkout $SHA"
SAFE=$(echo "$REF" | tr '/' '_')
OUT=$P/builds/$T/$SAFE-${SHA:0:10}
mkdir -p "$OUT"
say "$T at $REF = $SHA -> ${OUT#$P/}"
stamp() {
	{ echo "source $SHA"; echo "ref $REF"; echo "target $T"; echo "built $(date -Is) on $(hostname) in $(( $(date +%s) - START )) s"
	  echo "host $(grep PRETTY /etc/os-release | cut -d= -f2) $(uname -r)"; echo "result $1"; } > "$OUT/BUILD.txt"
	cat "$OUT/BUILD.txt"
}
ios_env() {	# iOS cross builds: our wrappers first (xcrun, codesign->ldid, nm/strip/lipo->LLVM, ios-cc)
	[ -n "$IOS_SDK" ] || die "no iPhoneOS SDK from xtool (run: xtool setup)"
	mkdir -p "$LBIN"; for f in "$HERE"/bin/*; do install -m755 "$f" "$LBIN/"; done	# wrappers as in this checkout
	export PATH="$LBIN:$PATH" IOS_SDK SDKROOT=$IOS_SDK
	mkdir -p "$R/work/userland/bin"
	ln -sf "$LBIN/ios-cc" "$R/work/userland/bin/ios-cc"
}

# ---- shim (shim.yml) ----
build_shim() {
	local mk=$SRC/mkbootimg avb=$SRC/avb
	[ -d "$mk/.git" ] || git clone -q --depth 1 https://github.com/LineageOS/android_system_tools_mkbootimg "$mk"
	[ -d "$avb/.git" ] || git clone -q --depth 1 https://github.com/LineageOS/android_external_avb "$avb"
	export MKBOOTIMG="python3 $mk/mkbootimg.py" AVBTOOL="python3 $avb/avbtool.py"
	cd "$R" && mkdir -p out
	SHIM_CFLAGS="-DSHIM_NO_UFS_WRITE -DSHIM_HOLDLOG" bash shim/build.sh "" "$PWD/out/redfin-probe-safe.img" || return 1
	bash shim/build.sh "" "$PWD/out/redfin-probe.img" || return 1
	cp shim/out/Image.lz4 out/shim-Image.lz4	# the kernel slot of rNN boot images (mkbootimg --kernel)
	cp shim/out/shim.elf out/
	(cd out && sha256sum *.img shim-Image.lz4 > SHA256SUMS && cat SHA256SUMS)
	cp out/* "$OUT/"
}

# ---- userland (userland.yml) ----
DROPBEAR_VER=2022.83 DASH_VER=0.5.12 TOYBOX_VER=0.8.11
dl() {	# URL -> cached file name
	mkdir -p "$SRC/dl"; local f=$SRC/dl/$(basename "$1")
	[ -s "$f" ] || curl -fsSL -o "$f" "$1" || return 1
	echo "$f"
}
build_userland() {
	ios_env
	local U=$TW/out; rm -rf "$U"; mkdir -p "$U"
	local t; t=$(dl https://matt.ucc.asn.au/dropbear/releases/dropbear-$DROPBEAR_VER.tar.bz2) || return 1
	( cd "$TW" && rm -rf dropbear-$DROPBEAR_VER && tar xjf "$t" && cd dropbear-$DROPBEAR_VER &&
	  cat > localoptions.h <<'EOH'
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PAM_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH 1
#define DROPBEAR_SVR_MULTIUSER 1
#define DROPBEAR_X11FWD 0
#define DEFAULT_PATH "/var/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
#define DEFAULT_ROOT_PATH "/var/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
#define DSS_PRIV_FILENAME "/private/etc/dropbear/dropbear_dss_host_key"
#define RSA_PRIV_FILENAME "/private/etc/dropbear/dropbear_rsa_host_key"
#define ECDSA_PRIV_FILENAME "/private/etc/dropbear/dropbear_ecdsa_host_key"
#define ED25519_PRIV_FILENAME "/private/etc/dropbear/dropbear_ed25519_host_key"
EOH
	  ./configure -q --host=aarch64-apple-darwin CC=ios-cc AR=llvm-ar RANLIB=llvm-ranlib --disable-zlib --disable-syslog \
		--disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
		--disable-loginfunc --disable-pututline --disable-pututxline --disable-harden &&
	  make -s -j"$JOBS" PROGRAMS="dropbear dropbearkey scp dbclient" MULTI=1 && cp dropbearmulti "$U/" ) || say "WARN dropbear failed"
	t=$(dl http://gondor.apana.org.au/~herbert/dash/files/dash-$DASH_VER.tar.gz) || return 1
	( cd "$TW" && rm -rf dash-$DASH_VER && tar xzf "$t" && cd dash-$DASH_VER &&
	  ./configure -q --host=aarch64-apple-darwin CC=ios-cc CC_FOR_BUILD=cc AR=llvm-ar RANLIB=llvm-ranlib ac_cv_func_strchrnul=no &&
	  make -s -j"$JOBS" && cp src/dash "$U/" ) || say "WARN dash failed"
	t=$(dl https://landley.net/toybox/downloads/toybox-$TOYBOX_VER.tar.gz) || return 1
	( cd "$TW" && rm -rf toybox-$TOYBOX_VER && tar xzf "$t" && cd toybox-$TOYBOX_VER &&
	  mkdir -p ios-inc/sys &&
	  printf '#include <sys/ioctl.h>\n#include <stdint.h>\n#define DKIOCGETBLOCKSIZE _IOR(%s, 24, uint32_t)\n#define DKIOCGETBLOCKCOUNT _IOR(%s, 25, uint64_t)\n' "'d'" "'d'" > ios-inc/sys/disk.h &&
	  make -s macos_defconfig HOSTCC=cc && CC=ios-cc HOSTCC=cc CFLAGS="-I$PWD/ios-inc -Wno-deprecated-declarations" LDOPTIMIZE=-Wl,-dead_strip STRIP=strip \
		make -s -j"$JOBS" toybox &&	# portability.sh picks Darwin link flags from `uname`: give them
	  cp toybox "$U/" ) || say "WARN toybox failed (continue-on-error in CI too)"
	cd "$R"
	sh phone/wifi/build.sh && cp phone/wifi/out/wland "$U/" || say "WARN wland failed"
	sh phone/sensors/test.sh > "$U/sensd-test.log" 2>&1 || { say "WARN sensd host tests failed"; tail -20 "$U/sensd-test.log"; }
	sh phone/sensors/build.sh && cp phone/sensors/out/sensd "$U/" || say "WARN sensd failed"
	sh phone/bt/build.sh && cp phone/bt/out/btd phone/bt/out/tlv_test.log "$U/" || say "WARN btd failed"
	sh phone/fastrpc/test.sh > "$U/fastrpcd-test.log" 2>&1 || { say "WARN fastrpcd host tests failed"; tail -20 "$U/fastrpcd-test.log"; }
	sh phone/fastrpc/build.sh && cp phone/fastrpc/out/fastrpcd phone/fastrpc/org.iosonpixel.fastrpcd.plist "$U/" || say "WARN fastrpcd failed"
	bash phone/tools/build.sh || say "WARN some phone tools failed"
	sh phone/haptics/build.sh && cp phone/haptics/out/SweetHaptics.dylib "$U/" || say "WARN SweetHaptics.dylib failed"
	sh phone/audio/build.sh > "$U/audio-build.log" 2>&1 && cp -R phone/audio/out/RedwoodAudio.driver phone/audio/out/sound_test \
		phone/audio/out/camera_test phone/audio/out/camera_avtest phone/audio/out/mg_test phone/audio/out/vt_test "$U/" ||
		{ say "WARN RedwoodAudio.driver failed"; tail -40 "$U/audio-build.log"; }
	for t in psx pstack netsvc nettest oslog prefs openapp lsreg memwarn pmem a2s imgdump mic_test; do
		[ -f phone/tools/out/$t ] && cp phone/tools/out/$t "$U/"; [ -f phone/audio/out/$t ] && cp phone/audio/out/$t "$U/"
	done
	cd "$U"
	local b
	for b in $(find . -maxdepth 1 -type f ! -name '*.log' | sed 's|^./||'); do
		if nm -m "$b" 2>/dev/null | grep -q "weak external"; then say "WARN $b has weak imports:"; nm -m "$b" | grep "weak external"; fi
		case $b in dash|dropbearmulti|toybox) codesign -f -s - "$b";; esac
		file "$b"
	done
	find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS
	cp -R "$U"/. "$OUT/"
	[ -f "$OUT/dropbearmulti" ] && [ -d "$OUT/RedwoodAudio.driver" ]
}

# ---- metal2 (metal2.yml) ----
MESA_COMMIT=85fda3b36405bcaea8bffc64aa4f2651dc90770d UNIXNU_M2_COMMIT=e95b37d97875bd8b30c976fcdef44d35d9c27bf3 M2V_COMMIT=720ef1ce
build_metal2() {
	ios_env
	cd "$R"
	local V=$WORK/metal2-venv
	[ -x "$V/bin/meson" ] || { python3 -m venv "$V" && "$V/bin/pip" install -q meson mako pyyaml packaging; } || return 1
	mkdir -p work/turnip && ln -sfn "$V" work/turnip/venv
	rustup toolchain list | grep -q '^1.98.0' || rustup toolchain install 1.98.0 --profile minimal --target aarch64-apple-ios || return 1
	# Mesa + UniXNU's mesa patches + ours: a fresh tree per run (the meson build dir is kept in $TW/turnip-build)
	local MM=$SRC/mesa	# one blobless checkout, reset to MESA_COMMIT and re-patched each run (only patched files change)
	[ -d "$MM/.git" ] || git clone -q --filter=blob:none --no-checkout https://gitlab.freedesktop.org/mesa/mesa.git "$MM" || return 1
	git -C "$MM" cat-file -e "$MESA_COMMIT^{commit}" 2>/dev/null || git -C "$MM" fetch -q origin "$MESA_COMMIT"
	local UM=$SRC/UniXNU-metal2
	[ "$(git -C "$UM" rev-parse HEAD 2>/dev/null)" = "$UNIXNU_M2_COMMIT" ] || { rm -rf "$UM"; git init -q "$UM";
		git -C "$UM" fetch -q --depth 1 "$UNIXNU_URL" "$UNIXNU_M2_COMMIT" && git -C "$UM" checkout -q FETCH_HEAD; } || return 1
	rm -rf work/turnip/mesa work/unixnu && ln -sfn "$UM" work/unixnu
	git -C "$MM" checkout -q -f "$MESA_COMMIT" && git -C "$MM" reset -q --hard && git -C "$MM" clean -fdxq || return 1
	ln -sfn "$MM" work/turnip/mesa
	( cd "$MM"
	  for p in $(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['patches']))" "$UM/scripts/data/adreno-compiler-inputs.json"); do
		echo "apply $p"; git apply --whitespace=nowarn "$UM/$p" || exit 1
	  done
	  for p in "$R"/phone/turnip/patches/*.patch; do echo "apply $p"; git apply --whitespace=nowarn "$p" || exit 1; done ) || return 1
	# keep the meson build dir between runs (sources changed -> ninja rebuilds what changed)
	# a new wrapper set (bin/*) invalidates meson's cached compiler checks: configure again from scratch
	local wh; wh=$(cat "$HERE"/bin/* | sha1sum | cut -c1-12)
	[ "$(cat "$TW/turnip-build/.lb-wrappers" 2>/dev/null)" = "$wh" ] || { rm -rf "$TW/turnip-build"; mkdir -p "$TW/turnip-build"; }
	ln -sfn "$TW/turnip-build" work/turnip/build-ios
	sh tools/build-turnip-ios.sh || { cp "$TW/turnip-build/meson-logs/meson-log.txt" "$OUT/" 2>/dev/null
		tail -40 work/turnip/build-ios.log work/turnip/configure-ios.log 2>/dev/null; return 1; }
	echo "$wh" > "$TW/turnip-build/.lb-wrappers"
	local M2=$SRC/metal2vulkan
	[ -d "$M2/.git" ] || git clone -q https://github.com/steelbrain/metal2vulkan.git "$M2"
	rm -rf work/metal2vulkan && git clone -q --shared "$M2" work/metal2vulkan && git -C work/metal2vulkan checkout -q "$M2V_COMMIT" || return 1
	for p in phone/metal2/bridge/patches/*.patch; do echo "apply $p"; git -C work/metal2vulkan apply --whitespace=nowarn "$PWD/$p" || return 1; done
	sed -i "s|/opt/homebrew/opt/llvm/bin/llvm-as|$(command -v llvm-as)|" tools/build-m2v-bridge.sh
	export CC_aarch64_apple_ios="$LBIN/ios-cc" AR_aarch64_apple_ios=llvm-ar CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$LBIN/ios-cc"
	sh tools/build-m2v-bridge.sh || return 1
	sh phone/metal2/build.sh || return 1
	cp work/turnip/build-ios/src/freedreno/vulkan/libvulkan_freedreno.dylib phone/metal2/out/
	sh phone/turnip/build.sh || say "WARN turnip tests failed"
	ios-cc -x c++ -std=c++17 -O2 -I phone/turnip -o phone/turnip/out/v2test phone/turnip/v2test.cpp -lc++ -framework IOKit -framework CoreFoundation &&
		codesign -f -s - phone/turnip/out/v2test || true
	(cd phone/metal2/out && tar cf - --exclude='*.dSYM' .) | tar xf - -C "$OUT"; mkdir -p "$OUT/turnip"	# dSYM (190 MB) stays in WSL; cp -R phone/turnip/out/. "$OUT/turnip/" 2>/dev/null
	[ -d "$OUT/SweetMetal2.bundle" ]
}

# ---- xnu (xnu.yml) ----
build_xnu() { bash "$HERE/xnu.sh" "$R" "$OUT"; }

LOG=$OUT/build.log
say "log -> ${LOG#$P/}"
if "build_$T" > >(tee "$LOG") 2>&1; then stamp ok; else stamp FAILED; exit 1; fi
