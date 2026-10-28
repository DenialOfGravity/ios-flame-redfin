#!/bin/sh
# labtrace.sh OUT MODE [SWEETTRACE FLAGS...]: one exp-run.py trace on the phone (exp-run.py copies this file to
# /var/tmp/labtrace.sh over ssh and runs it with /bin/sh). Same timing as agent/tmp/flingtrace2.sh: sweettrace -t 8 -d 1
# in the background, then inside the window
#   settings  6 vertical flings 0.3 s apart (Settings must be open)
#   pages     6 home-page swipes 0.75 s apart, alternating left/right
#   scroll    6 vertical flings up then 6 down (o2-lib.sh fl) - any scrolling app
#   idle      no input
# The swipes go to the kernel's command server from the phone itself (UDP 5141; each nc wrapped in timeout 1: a bare
# nc can hang). FLAGS default: -f -z (reduced, gzip; sweettrace from ws-u-lab). Prints sweettrace's output.
O=$1; M=${2:-settings}
shift 2 2>/dev/null || shift $#
[ $# -gt 0 ] || set -- -f -z
/var/local/bin/sweettrace -t 8 -d 1 "$@" -o $O > $O.log 2>&1 &
sleep 1.5
sw() { printf "$1" | toybox timeout 1 toybox nc -u 192.168.7.2 5141; }
case $M in
settings)
	for i in 1 2 3 4 5 6; do sw 'swipe 540 1900 540 600 120'; sleep 0.3; done;;
pages)
	for i in 1 2 3 4 5 6; do
		if [ $((i % 2)) = 1 ]; then sw 'swipe 900 1200 180 1200 250'; else sw 'swipe 180 1200 900 1200 250'; fi
		sleep 0.75
	done;;
scroll)
	for i in 1 2 3 4 5 6; do sw 'swipe 540 1900 540 600 120'; sleep 0.3; done
	sleep 0.6
	for i in 1 2 3 4 5 6; do sw 'swipe 540 600 540 1900 120'; sleep 0.3; done;;
esac
wait
cat $O.log
