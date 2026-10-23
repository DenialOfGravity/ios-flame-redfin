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
	sudo apt-get install -y python3 curl rsync hfsprogs fuse3 build-essential cmake git \
		libfuse3-dev zlib1g-dev libbz2-dev libattr1-dev libicu-dev
	if ! sudo apt-get install -y apfs-fuse 2>/dev/null; then
		echo "apfs-fuse not packaged here: building it from source"
		rm -rf "$W/apfs-fuse" && git clone --depth 1 --recursive https://github.com/sgan81/apfs-fuse "$W/apfs-fuse"
		cmake -S "$W/apfs-fuse" -B "$W/apfs-fuse/build" -DCMAKE_CXX_FLAGS="-include cstdint"
		make -C "$W/apfs-fuse/build" -j"$(nproc)"
		sudo install -m 0755 "$W/apfs-fuse/build/apfs-fuse" /usr/local/bin/apfs-fuse
	fi
}

hfsmod() {
	# Microsoft's WSL kernel is built without CONFIG_HFSPLUS_FS. Build just that module from the exact
	# kernel source tag and the running kernel's config. Config has MODVERSIONS (genksyms, type based),
	# no module signing, no randstruct: a vmlinux build of the same source + config gives matching symbol
	# CRCs, so the module loads normally. Debug info is turned off to save time; it does not change
	# types or CRCs. Nothing about the installed WSL kernel is changed; the module is gone after
	# `wsl --shutdown` (run this again: it reuses the built .ko).
	local rel ver tag src ko=$W/hfsplus.ko
	rel=$(uname -r); ver=${rel%%-*}; tag=linux-msft-wsl-$ver
	if grep -qw hfsplus /proc/filesystems; then echo "hfsplus already available"; return; fi
	if [[ ! -f $ko ]]; then
		sudo apt-get install -y build-essential flex bison bc libelf-dev libssl-dev cpio
		src=$W/WSL2-Linux-Kernel-$tag
		if [[ ! -d $src ]]; then
			curl -fL "https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/$tag.tar.gz" -o "$W/$tag.tar.gz"
			tar -xzf "$W/$tag.tar.gz" -C "$W"
		fi
		cd "$src"
		if [[ ! -f .config ]]; then
			if [[ -r /proc/config.gz ]]; then zcat /proc/config.gz > .config; else cp arch/x86/configs/config-wsl .config; fi
		fi
		scripts/config --module HFSPLUS_FS --disable DEBUG_INFO_BTF --disable DEBUG_INFO_DWARF5 \
			--disable DEBUG_INFO_DWARF4 --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --enable DEBUG_INFO_NONE
		make olddefconfig >/dev/null
		grep -q '^CONFIG_HFSPLUS_FS=m' .config || { echo "HFSPLUS_FS did not stick in .config"; exit 1; }
		echo "building vmlinux for symbol versions ($(nproc) jobs; 15-30 min)"
		make -j"$(nproc)" vmlinux modules_prepare >"$W/kbuild.log" 2>&1 || { tail -30 "$W/kbuild.log"; exit 1; }
		# `make vmlinux` writes the kernel's symbol CRCs to vmlinux.symvers; Module.symvers only appears
		# after a full `make modules`. The external module build reads Module.symvers.
		[[ -s Module.symvers ]] || cp vmlinux.symvers Module.symvers
		grep -q 'register_filesystem' Module.symvers || { echo "no register_filesystem CRC in Module.symvers"; exit 1; }
		make -j"$(nproc)" M=fs/hfsplus modules >>"$W/kbuild.log" 2>&1 || { tail -30 "$W/kbuild.log"; exit 1; }
		cp fs/hfsplus/hfsplus.ko "$ko"
		cd "$REPO"
	fi
	local magic; magic=$(modinfo -F vermagic "$ko" | awk '{print $1}')
	[[ $magic == "$rel" ]] || { echo "vermagic $magic != running $rel: rebuild (delete $ko)"; exit 1; }
	sudo insmod "$ko"
	grep -qw hfsplus /proc/filesystems && echo "hfsplus: loaded ($ko)" || { echo "hfsplus: insmod did not register it"; dmesg | tail -5; exit 1; }
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
        assert data[:4] != b'bvx2', 'LZFSE-compressed payload: use `ipsw img4 im4p extract`'
        open(sys.argv[2], 'wb').write(data)
        print(f'{sys.argv[2]}: {len(data)} bytes')
        break
    o = vo + vl
else:
    raise SystemExit('no payload in IM4P')
PY
}

build() {
	local img="$W/iosroot.img"
	grep -qw hfsplus /proc/filesystems || { echo "no hfsplus in the kernel: run '$0 hfsmod' first"; exit 1; }
	[[ -e $img ]] && { echo "$img exists: move it away to rebuild"; exit 1; }
	bash "$REPO/tools/mkiosroot.sh" "$W/ipsw/${PARTS[0]}" "$W/ipsw/${PARTS[1]}" "$W/ipsw/${PARTS[2]}" "$img" 16G 2>&1 |
		tee "$W/mkiosroot.log"
	echo "== tweaks"
	sudo fsck.hfsplus -fy "$img" | grep -v 'Illegal name' || true
	mkdir -p "$W/mnt"
	sudo mount -t hfsplus -o loop,force "$img" "$W/mnt"
	sudo python3 -I "$REPO/tools/sweet-root-tweaks.py" "$W/mnt" || { sudo umount "$W/mnt"; exit 1; }
	sudo umount "$W/mnt"
	sudo fsck.hfsplus -f -n "$img"
	echo "== d22ap.adt (iPhone X device tree, /product node for mkadt.py)"
	mkdir -p "$REPO/research/ipsw-x"
	d22ap "$W/ipsw/${PARTS[3]}" "$REPO/research/ipsw-x/d22ap.adt"
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
	ls -ls "$img"
	echo "build: done -> $img (stays in WSL; the install step streams it to the phone from here)"
}

case "${1:-}" in
check) check ;;
deps) deps ;;
hfsmod) hfsmod ;;
fetch) fetch ;;
build) build ;;
all) deps; hfsmod; fetch; build ;;
*) sed -n 2,16p "$0"; exit 2 ;;
esac
