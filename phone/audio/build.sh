#!/bin/sh
# Build RedwoodAudio.driver, HackiOS's CoreAudio HAL plug-in (MIT, LICENSE.HackiOS; from
# github.com/oosexgang/hackios-xnu-userland a79ff07 userland/src, unchanged), into phone/audio/out.
# It gives iOS the iPhone X's built-in devices: Speaker -> /dev/redwood-audio, Actuator (haptics)
# -> /dev/redwood-haptic (xnu 0914, bsd/dev/sweet_audio.c). Install with tools/redfin-install-audio.sh.
set -e
cd "$(dirname "$0")"
mkdir -p out/RedwoodAudio.driver
../../work/userland/bin/ios-cc -O2 -Wall -Wno-unused-parameter -bundle -framework CoreFoundation \
	-o out/RedwoodAudio.driver/RedwoodAudio audio_plugin.c
cp audio_plugin.plist out/RedwoodAudio.driver/Info.plist
codesign -f -s - out/RedwoodAudio.driver/RedwoodAudio
ls -la out/RedwoodAudio.driver
