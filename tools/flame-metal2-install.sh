#!/bin/sh
# Install phone/metal2/out/SweetMetal2.bundle on the phone (/System/Library/Extensions) and restart backboardd.
#   tools/flame-metal2-install.sh [--no-restart]       (boot with sweetmtl=2 to use it)
set -e
cd "$(dirname "$0")/.."
B=phone/metal2/out/SweetMetal2.bundle
for f in SweetMetal2 libvulkan_freedreno.dylib Info.plist _CodeSignature/CodeResources; do
	[ -s "$B/$f" ] || { echo "incomplete bundle: no $B/$f (build failed?)" >&2; exit 1; }
done
tools/flame-ssh 'rm -rf /var/local/tmp/m2 && mkdir -p /var/local/tmp/m2 && : >> /var/local/mtl2.log && chmod 666 /var/local/mtl2.log'
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname wheel -czf - -C phone/metal2/out \
	SweetMetal2.bundle | tools/flame-ssh 'toybox zcat | tar -xpf - -C /var/local/tmp/m2'
tools/flame-ssh 'rm -rf /System/Library/Extensions/SweetMetal2.bundle.old; [ -d /System/Library/Extensions/SweetMetal2.bundle ] &&
	mv /System/Library/Extensions/SweetMetal2.bundle /System/Library/Extensions/SweetMetal2.bundle.old;
	mv /var/local/tmp/m2/SweetMetal2.bundle /System/Library/Extensions/ && rm -rf /System/Library/Extensions/SweetMetal2.bundle.old;
	ls -la /System/Library/Extensions/SweetMetal2.bundle'
[ "$1" = --no-restart ] || tools/flame-ssh 'psx -k backboardd' || true
