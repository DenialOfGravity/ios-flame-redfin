#!/bin/bash
# Local builds of the redfin port in WSL (Linux), without a Mac or GitHub's macOS runners.
#   lb.sh env                    report the build host
#   lb.sh setup STEP             toolchain step (see setup.sh), into $BR/toolchain
#   lb.sh build TARGET [REF]     shim | userland | metal2 | xnu  at REF (branch or commit, default redfin-qol)
# Runs as the user, never root. Normally started by the phone agent (build-env, build-setup, build), which puts
# the log in builds/logs; results go to builds/<TARGET>/<REF>-<sha>/ in the project folder.
set -uo pipefail
P=${P:-/mnt/c/ClaudeProjects/iOS_Pixel5}
HERE=$(cd "$(dirname "$0")" && pwd)
BR=${BR:-$HOME/redfin-build}
TC=$BR/toolchain
mkdir -p "$BR"

cmd=${1:-env}; shift || true
case $cmd in
env)
	echo "== host"; uname -srm; grep PRETTY /etc/os-release; echo "cpus $(nproc)"; free -g | head -2
	df -h "$HOME" | tail -1; df -h /mnt/c | tail -1
	echo "== tools"
	for t in git python3 make cmake ninja meson clang clang++ ld.lld ld64.lld llvm-config llvm-as lz4 cpio flex bison \
		unifdef tcsh ldid swift swiftc xtool rustup cargo glslangValidator dtc gh; do
		printf '%-18s %s\n' "$t" "$(command -v $t 2>/dev/null || echo -)"
	done
	clang --version 2>/dev/null | head -1; llvm-config --version 2>/dev/null; swift --version 2>&1 | head -1
	ls ~/.local/share/swiftly/toolchains 2>/dev/null
	echo "== Darwin SDKs (xtool / swift sdk)"
	swift sdk list 2>/dev/null
	for d in ~/.swiftpm/swift-sdks ~/.local/share/xtool ~/.xtool ~/.config/xtool ~/.local/share/swiftpm/swift-sdks; do
		[ -d "$d" ] && { echo "-- $d"; find "$d" -maxdepth 7 \( -name '*.sdk' -o -name 'toolset*.json' -o -name 'swift-sdk.json' \) 2>/dev/null | head -20; }
	done
	find ~ -maxdepth 8 -name 'iPhoneOS*.sdk' -not -path '*/mnt/*' 2>/dev/null | head
	for d in $(find ~ -maxdepth 8 -type d -name bin -path '*toolset*' 2>/dev/null | head -3) \
		$(find ~ -maxdepth 8 -type f -name ld64 2>/dev/null | xargs -r -n1 dirname | head -3); do
		echo "-- $d"; ls "$d" | tr '\n' ' '; echo
	done
	echo "== $BR"; ls "$BR" "$TC" 2>/dev/null
	[ -f "$TC/READY" ] && cat "$TC/READY";;
setup) exec bash "$HERE/setup.sh" "$@";;
diag) . "$HERE/env.sh"; [ -f "$HERE/diag.sh" ] && . "$HERE/diag.sh";;
build) exec bash "$HERE/build.sh" "$@";;
*) echo "usage: lb.sh env | setup STEP | build TARGET [REF]"; exit 2;;
esac
