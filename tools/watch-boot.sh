#!/bin/sh
# Film the Pixel screen with the iPhone camera ("iPhone Xs Camera", AVFoundation)
# while `fastboot boot IMAGE` runs.
#
#   tools/watch-boot.sh OUTDIR SECONDS [IMAGE]
#
# OUTDIR/boot.mp4  full-resolution video (1920x1080, 10 fps, the phone appears rotated)
# OUTDIR/usb.txt   fastboot/adb presence over time (each change, with time)
# OUTDIR/sheet.jpg one frame every SECONDS/12 s as a 4x3 contact sheet
# Without IMAGE it only films. Pull a single frame later with:
#   ffmpeg -ss T -i OUTDIR/boot.mp4 -frames:v 1 OUT.jpg
out=$1; secs=$2; img=${3:-}
mkdir -p "$out"
ffmpeg -hide_banner -loglevel error -y -f avfoundation -framerate 30 -video_size 1920x1080 \
	-pixel_format nv12 -i "iPhone Xs Camera" -t "$secs" -r 10 -c:v h264_videotoolbox -b:v 8M \
	"$out/boot.mp4" &
fp=$!
start=$(date +%s)
sleep 2
if [ -n "$img" ]; then
	echo "$(date +%T) +$(($(date +%s) - start))s fastboot boot $img" | tee "$out/usb.txt"
	fastboot boot "$img" 2>&1 | tail -2 | tee -a "$out/usb.txt"
fi
prev=
while kill -0 $fp 2>/dev/null; do
	f=$(fastboot devices 2>/dev/null | awk '{print $1}' | head -1)
	a=$(adb devices 2>/dev/null | sed -n 2p | awk '{print $2}')
	cur="fb=[$f] adb=[$a]"
	[ "$cur" != "$prev" ] && echo "$(date +%T) +$(($(date +%s) - start))s $cur" | tee -a "$out/usb.txt"
	prev=$cur
	sleep 1
done
wait $fp
ffmpeg -hide_banner -loglevel error -y -i "$out/boot.mp4" \
	-vf "fps=12/$secs,scale=480:-1,tile=4x3" -frames:v 1 "$out/sheet.jpg"
ls -l "$out"
