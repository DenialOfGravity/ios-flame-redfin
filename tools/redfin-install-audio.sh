#!/bin/bash
# Install RedwoodAudio.driver (phone/audio, the CoreAudio HAL plug-in for the speaker and the haptics)
# on the running phone over the kernel file server; it is used from the next boot (mediaserverd loads
# HAL plug-ins once). Run from the repo:  tools/redfin-install-audio.sh [DIR containing RedwoodAudio.driver]
# Default DIR: phone/audio/out. Also needs a kernel with xnu 0914 and an ADT with /product/haptics.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=${1:-phone/audio/out}
D=$DIR/RedwoodAudio.driver
[ -f "$D/RedwoodAudio" ] && [ -f "$D/Info.plist" ] || { echo "no $D/RedwoodAudio + Info.plist"; exit 1; }
F="python3 -I tools/flame-files.py"
H=/System/Library/Audio/Plug-Ins/HAL
$F mkdir /System/Library/Audio 755 || true
$F mkdir /System/Library/Audio/Plug-Ins 755 || true
$F mkdir $H 755 || true
$F mkdir $H/RedwoodAudio.driver 755 || true
$F put "$D/Info.plist" $H/RedwoodAudio.driver/Info.plist 644
$F put "$D/RedwoodAudio" $H/RedwoodAudio.driver/RedwoodAudio 755
if [ -f "$D/_CodeSignature/CodeResources" ]; then
	$F mkdir $H/RedwoodAudio.driver/_CodeSignature 755 || true
	$F put "$D/_CodeSignature/CodeResources" $H/RedwoodAudio.driver/_CodeSignature/CodeResources 644
fi
echo "installed $H/RedwoodAudio.driver: reboot the phone into the new image"
