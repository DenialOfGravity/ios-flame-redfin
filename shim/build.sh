#!/bin/bash
# Build the redfin (Pixel 5) shim and wrap it in a boot image v3 (redbull BoardConfig:
# BOARD_BOOT_HEADER_VERSION 3, page 4096, boot partition 0x06000000).
# v3 has no load offsets and no DTB: ABL takes the DTB (and a vendor ramdisk) from
# vendor_boot on flash and places our ramdisk AFTER the vendor ramdisk, so the
# shim searches the initrd for the payload (loader.c find_payload).
#
#   shim/build.sh [PAYLOAD] [OUT]   PAYLOAD: tools/mkpayload.py output (ramdisk);
#                                   none -> probe-only image
#   SHIM_CFLAGS=-DSHIM_SHOWLOG shim/build.sh "" OUT
#                                   show the logs on UFS on screen (showlog.c)
# Needs llvm + lld + lz4 + mkbootimg (AOSP) + avbtool. No stock DTB is needed (v3).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
if [ -d /opt/homebrew/opt/llvm/bin ]; then
	LLVM=/opt/homebrew/opt/llvm/bin LLD=/opt/homebrew/opt/lld/bin
else
	LLVM=$(dirname "$(command -v clang)") LLD=$(dirname "$(command -v ld.lld)")
fi
CC="$LLVM/clang --target=aarch64-none-elf"
CFLAGS="-O2 -ffreestanding -nostdlib -fno-builtin -fno-pic -fno-pie -mgeneral-regs-only -mstrict-align
	-fno-stack-protector -fno-asynchronous-unwind-tables -Wall -Wextra ${SHIM_CFLAGS:-}"
SRCS="start.S shim.c console.c log.c util.c mmu.c fdt.c loader.c ufs.c spmi.c sde.c showlog.c diag.c disptest.c gpuprobe.c gpufw.S smmuprobe.c ramlog.c"
mkdir -p out
objs=
for f in $SRCS; do
	$CC $CFLAGS -c "$f" -o "out/${f%.*}.o"
	objs="$objs out/${f%.*}.o"
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($LLVM/llvm-readelf -r $(echo "$objs" | sed 's| out/start.o||') | grep -c R_AARCH64_ABS64 || true)
[ "$abs" = 0 ] || {
	$LLVM/llvm-readelf -r $(echo "$objs" | sed 's| out/start.o||') | grep -B5 R_AARCH64_ABS64 >&2
	echo "error: $abs absolute relocations in C objects" >&2
	exit 1
}
$LLD/ld.lld -static -nostdlib -T shim.ld --build-id=none -N $objs -o out/shim.elf
$LLVM/llvm-objcopy -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$($LLVM/llvm-nm out/shim.elf | awk '$3=="_end"{print $1}')
truncate -s $((16#$size)) out/Image
# Google's ABL only takes compressed kernels (stock and TWRP are LZ4 frames);
# an uncompressed Image is "Unsupported".
lz4 -q -9 -B7 -f out/Image out/Image.lz4
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	# ABL dislikes a zero-size ramdisk on some builds: an empty newc cpio.
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
OUT=${2:-out/shim-boot.img}
MKBOOTIMG=${MKBOOTIMG:-$(command -v mkbootimg || echo "python3 $ROOT/downloads/mkbootimg/mkbootimg.py")}
$MKBOOTIMG \
	--header_version 3 --kernel out/Image.lz4 --ramdisk out/ramdisk.bin \
	--os_version 14.0.0 --os_patch_level 2023-08 \
	--cmdline "console=null" -o "$OUT"
# Google's ABL refuses "fastboot boot" of an image without an AVB footer
# ("Error verifying the received boot.img: Unsupported"), even unlocked: add
# an unsigned hash footer (algorithm NONE) like TWRP's, padding to the boot
# partition size.
AVBTOOL=${AVBTOOL:-$(command -v avbtool || echo "python3 $ROOT/downloads/avb/avbtool.py")}
$AVBTOOL add_hash_footer --image "$OUT" \
	--partition_size 100663296 --partition_name boot	# 0x06000000 (redbull)
ls -l out/Image "$OUT"
