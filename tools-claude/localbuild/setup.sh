#!/bin/bash
# Toolchain for local builds, as the user (the apt packages come from the phone agent's build-apt).
#   setup.sh STEP     STEP: unixnu probe llvm cctools mig iig hostcc shims ldid rust | xnu-tools (all XNU steps) | all
# XNU's tools come from UniXNU's scripts/linux/setup-toolchain.py (pinned in env.sh), run step by step by tc.py into
# $TC instead of /opt with root: clang + llvm-xnu-builtin-type.patch (AArch64 only, ~30-40 min on 16 threads),
# cctools-port ld64-956.6 (the kernel link), mig from bootstrap_cmds-138, iig-port, the host compiler wrapper.
# Userland/metal2 use the distribution's clang 21 + ld64.lld, ldid for signatures and rustup.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/env.sh"
UX=$SRC/UniXNU

step_unixnu() {
	if [ "$(git -C "$UX" rev-parse HEAD 2>/dev/null)" != "$UNIXNU_COMMIT" ]; then
		rm -rf "$UX"; git init -q "$UX"
		git -C "$UX" fetch -q --depth 1 "$UNIXNU_URL" "$UNIXNU_COMMIT"
		git -C "$UX" checkout -q FETCH_HEAD
	fi
	say "UniXNU $(git -C "$UX" rev-parse --short HEAD)"
}
has_builtins() { printf '#if __has_builtin(__builtin_xnu_type_summary)\nok\n#endif\n' | "$1" -target arm64-apple-macos14.0 -E - 2>/dev/null | grep -qx ok; }
step_probe() {
	for c in "$XNU_CLANG" ~/.local/share/swiftly/toolchains/*/usr/bin/clang /usr/bin/clang; do
		[ -x "$c" ] || continue
		if has_builtins "$c"; then echo "xnu builtins: YES  $c"; else echo "xnu builtins: no   $c"; fi
	done
	echo "iOS SDK: ${IOS_SDK:-none}"; echo "macOS SDK: ${MAC_SDK:-none}"
	command -v ld64.lld ldid rustup llvm-as llvm-ar llvm-nm llvm-strip llvm-lipo llvm-otool dsymutil meson || true
}
tc() { step_unixnu >/dev/null; JOBS=$JOBS python3 -u "$HERE/tc.py" "$UX" "$TC" "$1"; }
step_llvm() {
	if [ -x "$XNU_CLANG" ] && has_builtins "$XNU_CLANG"; then say "clang ready: $XNU_CLANG"; return; fi
	tc llvm
	rm -rf "$TC/build-work/llvm-project"
}
step_shims() {
	step_unixnu
	mkdir -p "$CLT/bin" "$LBIN" "$TC/xnu-bin"
	# UniXNU's CLT shims: clang (CROSS_CLANG + DARWIN_TRIPLE), clang++, cc, install (BSD flags), gm4
	for s in clang clang++ cc install gm4; do install -m755 "$UX/scripts/linux/$s" "$CLT/bin/$s"; done
	# XNU make: UniXNU's plutil (plistlib) and no-op codesign; our xcrun (both modes)
	install -m755 "$UX/scripts/linux/plutil" "$TC/xnu-bin/plutil"
	install -m755 "$UX/scripts/linux/codesign" "$TC/xnu-bin/codesign"
	install -m755 "$HERE/bin/xcrun" "$TC/xnu-bin/xcrun"
	cp "$UX/scripts/linux/TargetConditionals.h" "$TC/TargetConditionals.h"
	# userland wrappers
	for f in "$HERE"/bin/*; do install -m755 "$f" "$LBIN/$(basename "$f")"; done
	ls "$LBIN" "$TC/xnu-bin" "$CLT/bin"
}
step_ldid() {
	command -v ldid >/dev/null && { ldid 2>&1 | head -2; return; }
	local d=$SRC/ldid
	[ -d "$d/.git" ] || git clone -q https://github.com/ProcursusTeam/ldid.git "$d"
	make -C "$d" -j"$JOBS"
	mkdir -p "$TC/bin"; cp "$d/ldid" "$TC/bin/ldid"; say "ldid -> $TC/bin/ldid"
}
step_rust() {
	if ! command -v rustup >/dev/null; then	# user install (~/.cargo), no PATH edits in the shell profile
		curl -sSf https://sh.rustup.rs | sh -s -- -y -q --no-modify-path --default-toolchain none --profile minimal
	fi
	rustup toolchain install 1.98.0 --profile minimal --target aarch64-apple-ios
	rustup run 1.98.0 rustc --version
}
case ${1:-} in
unixnu|probe|llvm|shims|ldid|rust) "step_$1";;
cctools|mig|iig|hostcc) step_unixnu; tc "$1";;
xnu-tools) step_unixnu; step_shims; tc cctools; tc mig; tc iig; tc hostcc; step_llvm; step_probe;;
all) step_unixnu; step_shims; step_ldid; step_rust; tc cctools; tc mig; tc iig; tc hostcc; step_llvm; step_probe;;
*) die "setup.sh unixnu|probe|llvm|cctools|mig|iig|hostcc|shims|ldid|rust|xnu-tools|all";;
esac
say "setup ${1} done"
