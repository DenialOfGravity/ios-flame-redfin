#!/bin/bash
# Build the iOS 16.7.16 (iPhone X, 20H392) root image for the Pixel 5 port in WSL (Ubuntu).
# Nothing here touches the phone. Run from the repo root inside WSL:
#
#   bash tools/redfin-mkroot-wsl.sh check      tools + kernel HFS+ support (changes nothing)
#   bash tools/redfin-mkroot-wsl.sh deps       apt install the build tools (sudo)
#   bash tools/redfin-mkroot-wsl.sh hfsmod     build + load hfsplus.ko for THIS WSL kernel (WSL's kernel has
#                                               no HFS+; ~15-30 min once; reload after `wsl --shutdown` with
#                                               the same command, which then only runs insmod)
#   bash tools/redfin-mkroot-wsl.sh fetch      download the IPSW parts from Apple (~6-7 GB)
#   bash tools/redfin-mkroot-wsl.sh build      mkiosroot.sh + sweet-root-tweaks.py -> iosroot.img (16 GiB)
#   bash tools/redfin-mkroot-wsl.sh finish     resume after build's tweaks: d22ap.adt, checksums, rename
#   bash tools/redfin-mkroot-wsl.sh all        deps + hfsmod + fetch + build
#
# Work files live in ~/redfin-work (WSL's own ext4 disk: fast, and loop mounts work there).
# The finished image and its per-GiB SHA-256 list are copied next to the repo in work/iosroot/.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
W=${REDFIN_WORK:-$HOME/redfin-work}
DEV=iPhone10,3 BUILD=20H392
# rootfs, SystemOS and AppOS cryptexes of 20H392 (HANDOFF.md, as used on flame/sunfish)
PARTS=(087-86698-044.dmg 087-86593-047.dmg 087-86715-047.dmg DeviceTree.d22ap.im4p)
mkdir -p "$W/ipsw"

check() {
	local ok=1
	echo "== tools"
	for t in python3 curl rsync apfs-fuse mkfs.hfsplus fsck.hfsplus sudo; do
		printf '  %-14s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
	done
	echo "== kernel HFS+ (mkiosroot.sh mounts the image read-write through the kernel)"
	if grep -qw hfsplus /proc/filesystems; then
		echo "  hfsplus: built in / loaded"
	elif sudo modprobe hfsplus 2>/dev/null && grep -qw hfsplus /proc/filesystems; then
		echo "  hfsplus: loaded as a module"
	else
		echo "  hfsplus: NOT AVAILABLE in this WSL kernel ($(uname -r))"; ok=0
	fi
	echo "== FUSE"; ls -l /dev/fuse 2>/dev/null || { echo "  /dev/fuse missing"; ok=0; }
	echo "== space in $W"; df -h "$W" | tail -1
	echo "  need ~30 GB free (6-7 GB IPSW parts + 16 GiB sparse image + copy)"
	[[ $ok == 1 ]] && echo "check: OK" || echo "check: kernel/FUSE support missing (see above)"
}

deps() {
	sudo apt-get update
	sudo apt-get install -y python3 curl rsync hfsprogs fuse3 dwarves build-essential cmake git \
		libfuse3-dev zlib1g-dev libbz2-dev libattr1-dev libicu-dev
	if ! sudo apt-get install -y apfs-fuse 2>/dev/null; then
		echo "apfs-fuse not packaged here: building it from source"
		rm -rf "$W/apfs-fuse" && git clone --depth 1 --recursive https://github.com/sgan81/apfs-fuse "$W/apfs-fuse"
		cmake -S "$W/apfs-fuse" -B "$W/apfs-fuse/build" -DCMAKE_CXX_FLAGS="-include cstdint" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
		make -C "$W/apfs-fuse/build" -j"$(nproc)"
		sudo install -m 0755 "$W/apfs-fuse/build/apfs-fuse" /usr/local/bin/apfs-fuse
	fi
}

hfsmod() {
	# Microsoft's WSL kernel is built without CONFIG_HFSPLUS_FS. Build just that module from the exact
	# kernel source tag. Two configs:
	#  A) for vmlinux, only to get the symbol CRCs (vmlinux.symvers): the running config with debug info
	#     off (fast; debug info does not change the genksyms CRCs).
	#  B) for the module itself: the running config EXACTLY, plus HFSPLUS_FS=m. struct module must have
	#     the running kernel's size, and CONFIG_DEBUG_INFO_BTF_MODULES adds fields to it (keeping BTF on
	#     in Kconfig needs pahole, from dwarves). The .gnu.linkonce.this_module size check is what
	#     rejected the first build ("Invalid module format").
	# Nothing about the installed WSL kernel is changed; the module is gone after `wsl --shutdown` (run
	# this again: it reuses the built .ko).
	local rel ver tag src ko=$W/hfsplus-v3.ko
	rel=$(uname -r); ver=${rel%%-*}; tag=linux-msft-wsl-$ver
	if grep -qw hfsplus /proc/filesystems; then echo "hfsplus already available"; return; fi
	[[ -r /proc/config.gz ]] || { echo "no /proc/config.gz: cannot match the running kernel's config"; exit 1; }
	if [[ ! -f $ko ]]; then
		sudo apt-get install -y build-essential flex bison bc libelf-dev libssl-dev cpio dwarves
		# GCC plugin headers, so CONFIG_GCC_PLUGINS (on in the running config) is kept
		sudo apt-get install -y "gcc-$(gcc -dumpversion | cut -d. -f1)-plugin-dev" || true
		src=$W/WSL2-Linux-Kernel-$tag
		if [[ ! -d $src ]]; then
			curl -fL "https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/$tag.tar.gz" -o "$W/$tag.tar.gz"
			tar -xzf "$W/$tag.tar.gz" -C "$W"
		fi
		cd "$src"
		# Symbol CRCs (genksyms) must come from the EXACT running config: CONFIG_DEBUG_INFO_BTF_MODULES
		# changes struct module, and with it the CRC of module_layout ("disagrees about version of symbol
		# module_layout" with CRCs from a BTF-off build). Same config, but compiled with -g0: debug info
		# does not change any type, and `vmlinux_o modpost` (not `vmlinux.o`: a .o goal switches kbuild
		# to single-file mode) writes vmlinux.symvers without the final
		# link, so no BTF/pahole pass over a DWARF-less vmlinux is needed.
		if [[ ! -f .symvers-exact-config ]]; then
			zcat /proc/config.gz > .config
			scripts/config --module HFSPLUS_FS
			make olddefconfig >/dev/null
			rm -f vmlinux vmlinux.nobtf vmlinux.o vmlinux.symvers Module.symvers
			echo "A) building vmlinux.o for symbol versions, exact config ($(nproc) jobs; 15-30 min)"
			make -j"$(nproc)" KCFLAGS=-g0 vmlinux_o modpost >"$W/kbuild.log" 2>&1 || { tail -30 "$W/kbuild.log"; exit 1; }
			[[ -s vmlinux.symvers ]] || { echo "vmlinux.symvers was not produced"; tail -30 "$W/kbuild.log"; exit 1; }
			touch .symvers-exact-config
		fi
		cp vmlinux.symvers Module.symvers
		grep -q 'register_filesystem' Module.symvers || { echo "no register_filesystem CRC in Module.symvers"; exit 1; }
		echo "B) module against the running config"
		zcat /proc/config.gz > .config
		scripts/config --module HFSPLUS_FS
		make olddefconfig >/dev/null
		grep -q '^CONFIG_HFSPLUS_FS=m' .config || { echo "HFSPLUS_FS did not stick in .config"; exit 1; }
		for o in DEBUG_INFO_BTF_MODULES MODVERSIONS MODULE_UNLOAD; do
			if zcat /proc/config.gz | grep -q "^CONFIG_$o=y" && ! grep -q "^CONFIG_$o=y" .config; then
				echo "CONFIG_$o is on in the running kernel but dropped here (struct module would differ)"; exit 1
			fi
		done
		make -j"$(nproc)" KCFLAGS=-g0 modules_prepare >>"$W/kbuild.log" 2>&1 || { tail -30 "$W/kbuild.log"; exit 1; }
		# Our vmlinux was built without BTF; with it present, the module's BTF step fails ("failed to
		# find '.BTF'"). Without a vmlinux, Makefile.modfinal skips module BTF, which the running kernel
		# does not need (MODULE_ALLOW_BTF_MISMATCH=y, BTF is optional for modules).
		[[ -f vmlinux ]] && mv vmlinux vmlinux.nobtf || true
		make -j"$(nproc)" KCFLAGS=-g0 M=fs/hfsplus modules >>"$W/kbuild.log" 2>&1 || { tail -30 "$W/kbuild.log"; exit 1; }
		cp fs/hfsplus/hfsplus.ko "$ko"
		cd "$REPO"
	fi
	local magic; magic=$(modinfo -F vermagic "$ko" | awk '{print $1}')
	[[ $magic == "$rel" ]] || { echo "vermagic $magic != running $rel: rebuild (delete $ko)"; exit 1; }
	if ! sudo insmod "$ko" 2>/dev/null; then
		# gcc 15 here vs Microsoft's gcc 13: compiler-detected options (CC_HAS_*, asm-goto) change
		# preprocessed header text, so the genksyms CRC of module_layout differs although struct module
		# has the running kernel's size (that check passes). The config is the running one apart from
		# those options; verify that, then drop the module's __versions table: with
		# CONFIG_MODULE_FORCE_LOAD=y the kernel loads it as a forced module (taint F) instead of comparing
		# CRCs. Only this WSL session's kernel is affected; nothing persists past `wsl --shutdown`.
		local src=$W/WSL2-Linux-Kernel-$tag diffs
		diffs=$(zcat /proc/config.gz | diff - "$src/.config" | grep '^[<>] CONFIG' |
			grep -Ev 'CONFIG_(CC_VERSION_TEXT|GCC_VERSION|AS_VERSION|LD_VERSION|PAHOLE_VERSION|CC_HAS_[A-Z0-9_]+|GCC_ASM_GOTO_OUTPUT_BROKEN|HFSPLUS_FS)=' || true)
		if [[ -n $diffs ]]; then
			echo "insmod refused and the config differs beyond compiler-detected options:"; echo "$diffs"; sudo dmesg | tail -3; exit 1
		fi
		sudo dmesg | tail -1
		echo "CRC mismatch from the compiler version only: loading as a forced module (no __versions)"
		objcopy --remove-section=__versions "$ko" "${ko%.ko}-nover.ko"
		sudo insmod "${ko%.ko}-nover.ko" || { sudo dmesg | tail -3; exit 1; }
	fi
	grep -qw hfsplus /proc/filesystems && echo "hfsplus: loaded ($ko)" || { echo "hfsplus: insmod did not register it"; sudo dmesg | tail -5; exit 1; }
}

fetch() {
	local url
	url=$(curl -sfL "https://api.ipsw.me/v4/device/$DEV?type=ipsw" |
		python3 -c "import json,sys; print(next(f['url'] for f in json.load(sys.stdin)['firmwares'] if f['buildid']=='$BUILD'))")
	echo "IPSW: $url"
	echo "$url" > "$W/ipsw/URL"
	for p in "${PARTS[@]}"; do
		# remotezip.py checks each member's zip CRC-32 and resumes partial downloads
		python3 -I "$REPO/tools/remotezip.py" "$url" "$p" "$W/ipsw"
	done
	ls -l "$W/ipsw"
}

d22ap() {
	# DeviceTree.d22ap.im4p -> d22ap.adt (IM4P = DER SEQUENCE {IA5 "IM4P", IA5 type, IA5 desc, OCTET payload})
	python3 - "$1" "$2" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
def tlv(o):
    t = b[o]; l = b[o + 1]; o += 2
    if l & 0x80:
        n = l & 0x7f; l = int.from_bytes(b[o:o + n], 'big'); o += n
    return t, o, l
t, o, l = tlv(0); assert t == 0x30
end = o + l
while o < end:
    t, vo, vl = tlv(o)
    if t == 0x04:
        data = b[vo:vo + vl]
        out = sys.argv[2] + ('.lzfse' if data[:4] == b'bvx2' else '')
        open(out, 'wb').write(data)
        print(f'{out}: {len(data)} bytes')
        break
    o = vo + vl
else:
    raise SystemExit('no payload in IM4P')
PY
}

build() {
	local final="$W/iosroot.img" img="$W/iosroot.img.partial"
	grep -qw hfsplus /proc/filesystems || { echo "no hfsplus in the kernel: run '$0 hfsmod' first"; exit 1; }
	[[ -e $final ]] && { echo "$final exists: move it away to rebuild"; exit 1; }
	# A failed run leaves only the .partial image: start over from scratch.
	rm -f "$img"
	bash "$REPO/tools/mkiosroot.sh" "$W/ipsw/${PARTS[0]}" "$W/ipsw/${PARTS[1]}" "$W/ipsw/${PARTS[2]}" "$img" 16G 2>&1 |
		tee "$W/mkiosroot.log"
	[[ ${PIPESTATUS[0]} == 0 ]] || { echo "mkiosroot.sh failed (log: $W/mkiosroot.log)"; exit 1; }
	echo "== tweaks"
	sudo fsck.hfsplus -fy "$img" | grep -v 'Illegal name' || true
	mkdir -p "$W/mnt"
	sudo mount -t hfsplus -o loop,force "$img" "$W/mnt"
	sudo python3 -I "$REPO/tools/sweet-root-tweaks.py" "$W/mnt" || { sudo umount "$W/mnt"; exit 1; }
	sudo umount "$W/mnt"
	sudo fsck.hfsplus -f -y "$img" | grep -v 'Illegal name' || true
	sudo fsck.hfsplus -f -n "$img" || echo "warning: fsck_hfs still reports minor issues; continuing"
	finish
}

finish() {
	# The steps after the image is built and tweaked (also usable on its own to resume after a
	# failure here, without rebuilding the image).
	local final="$W/iosroot.img" img="$W/iosroot.img.partial" im4p
	[[ -f $img ]] || { [[ -f $final ]] && img=$final; } || true
	[[ -f $img ]] || { echo "no $W/iosroot.img(.partial): run build"; exit 1; }
	echo "== d22ap.adt (iPhone X device tree, /product node for mkadt.py)"
	# remotezip.py keeps the member's path (Firmware/all_flash/DeviceTree.d22ap.im4p)
	im4p=$(find "$W/ipsw" -name 'DeviceTree.d22ap.im4p' | head -1)
	[[ -n $im4p ]] || { echo "DeviceTree.d22ap.im4p not found under $W/ipsw: run fetch"; exit 1; }
	mkdir -p "$REPO/research/ipsw-x"
	local adt=$REPO/research/ipsw-x/d22ap.adt
	rm -f "$adt" "$adt.lzfse"
	d22ap "$im4p" "$adt"
	if [[ -f $adt.lzfse ]]; then
		# The payload is LZFSE (bvx2): decode it with Apple's reference lzfse tool, built from the
		# copy that came with the apfs-fuse source (or a fresh clone).
		local lz=$W/lzfse-bin
		if [[ ! -x $lz ]]; then
			local lsrc=$W/apfs-fuse/3rdparty/lzfse
			[[ -f $lsrc/src/lzfse_main.c ]] || { rm -rf "$W/lzfse"; git clone -q --depth 1 https://github.com/lzfse/lzfse "$W/lzfse"; lsrc=$W/lzfse; }
			cc -O2 -o "$lz" "$lsrc"/src/*.c
		fi
		"$lz" -decode -i "$adt.lzfse" -o "$adt"
		rm -f "$adt.lzfse"
		ls -l "$adt"
	fi
	if python3 -I "$REPO/tools/adt.py" dump "$adt" 2>/dev/null | grep -q 'product'; then
		echo "d22ap.adt parses, /product present"
	else
		echo "d22ap.adt does not parse as an ADT:"; head -c 64 "$adt" | od -A x -t x1z | head -4; exit 1
	fi
	echo "== per-GiB SHA-256 (to check the copy on the phone)"
	mkdir -p "$REPO/work/iosroot"
	python3 - "$img" "$REPO/work/iosroot/iosroot.gib.sha256" <<'PY'
import hashlib, sys
with open(sys.argv[1], 'rb') as f, open(sys.argv[2], 'w') as o:
    i = 0
    while True:
        h = hashlib.sha256(); n = 0
        while n < 1 << 30:
            c = f.read(1 << 22)
            if not c: break
            h.update(c); n += len(c)
        if not n: break
        o.write(f'{i} {h.hexdigest()}\n'); i += 1
print(f'{sys.argv[2]}: {i} GiB')
PY
	[[ $img == "$final" ]] || { mv "$img" "$final"; img=$final; }
	ls -ls "$img"
	echo "build: done -> $img (stays in WSL; the install step streams it to the phone from here)"
}

case "${1:-}" in
check) check ;;
deps) deps ;;
hfsmod) hfsmod ;;
fetch) fetch ;;
build) build ;;
finish) finish ;;
all) deps; hfsmod; fetch; build ;;
*) sed -n 2,17p "$0"; exit 2 ;;
esac
