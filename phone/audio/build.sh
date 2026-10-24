#!/bin/sh
# Build RedwoodAudio.driver, HackiOS's CoreAudio HAL plug-in (MIT, LICENSE.HackiOS; from
# github.com/oosexgang/hackios-xnu-userland a79ff07 userland/src, unchanged), into phone/audio/out.
# It gives iOS the iPhone X's built-in devices: Speaker -> /dev/redwood-audio, Actuator (haptics)
# -> /dev/redwood-haptic (xnu 0914, bsd/dev/sweet_audio.c). Install with tools/redfin-install-audio.sh.
set -e
cd "$(dirname "$0")"
mkdir -p out/RedwoodAudio.driver
# The bundle also carries HackiOS's camera for iOS (MIT; inject_media.c, camera_device.c, camera_isp.c): mediaserverd,
# which loads this plug-in, is where the capture stack lives; with the kernel's /dev/redwood-camera (xnu 0923,
# sweetcamdev=1) the capture device vendor is given camera_device.c's device, and without it nothing is touched.
../../work/userland/bin/ios-cc -O2 -Wall -Wno-unused-parameter -Wno-unused-function -bundle -framework CoreFoundation \
	-framework CoreMedia -framework CoreVideo -framework IOSurface -lobjc \
	-o out/RedwoodAudio.driver/RedwoodAudio audio_plugin.c inject_media.c camera_device.c camera_isp.c
cp audio_plugin.plist out/RedwoodAudio.driver/Info.plist
codesign -f -s - out/RedwoodAudio.driver/RedwoodAudio
# sound_test (HackiOS, MIT, unchanged): plays tones, system sounds and CoreHaptics patterns the way an app does
../../work/userland/bin/ios-cc -O2 -Wall -Wno-unused-parameter -framework CoreFoundation -framework AudioToolbox \
	-framework AVFoundation -lobjc -o out/sound_test sound_test.c
codesign -f -s - out/sound_test
# camera_test (HackiOS, MIT): /dev/redwood-camera's frames as a program gets them, with camera_isp.c
../../work/userland/bin/ios-cc -O2 -Wall -Wno-unused-parameter -o out/camera_test camera_test.c camera_isp.c
codesign -f -s - out/camera_test
ls -la out/RedwoodAudio.driver out/sound_test out/camera_test
