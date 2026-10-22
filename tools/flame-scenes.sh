#!/bin/bash
# Drive the running iOS through a fixed set of scenes and grab each one from the
# panel (tools/flame-shot), to compare renderers (CPU vs SweetMetal) shot by shot.
#
#   tools/flame-scenes.sh OUTDIR [SCENE...]     (default: all; starts from the lock screen)
#
# Boot with -G either way (GPU present, frames fitted, panel stride 4352) so the
# shots line up; sweetmtl=1 or not picks the renderer. Coordinates are panel
# pixels for Apple's default home screen layout (page 1) under the fit.
set -uo pipefail
cd "$(dirname "$0")/.."
out=$1; shift
mkdir -p "$out"
cmd() { python3 tools/flame-cmd.py "$@" >/dev/null 2>&1; }
home() { cmd swipe 540 2270 540 1100 300; sleep 2; }
shot() { tools/flame-shot --stride 4352 "$out/$1.png" >/dev/null 2>&1 || echo "$1: shot failed"; echo "$1"; }
app() { cmd tap "$2" "$3"; sleep 4; shot "$1"; home; }

scenes=${*:-lock home settings general control notifications today spotlight clock calendar notes photos safari}
for s in $scenes; do
	case $s in
	lock) shot lock ;;
	home) home; sleep 1; shot home ;;
	settings) app settings 660 1617 ;;
	general) cmd tap 660 1617; sleep 4; cmd tap 300 1810; sleep 3; shot general; home ;;
	control) cmd swipe 900 20 900 1200 300; sleep 3; shot control; cmd swipe 540 2000 540 400 200; sleep 2 ;;
	notifications) cmd swipe 400 20 400 1500 300; sleep 3; shot notifications; home ;;
	today) cmd swipe 100 1200 1000 1200 300; sleep 3; shot today; cmd swipe 1000 1200 100 1200 300; sleep 2 ;;
	spotlight) cmd swipe 540 1000 540 1600 300; sleep 3; shot spotlight; home ;;
	clock) app clock 903 816 ;;
	calendar) app calendar 414 1350 ;;
	notes) app notes 414 816 ;;
	photos) app photos 660 1350 ;;
	safari) app safari 414 2121 ;;
	*) echo "unknown scene $s" ;;
	esac
done
