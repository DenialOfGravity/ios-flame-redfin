#!/bin/bash
# Scripted UI load + fps readout from the live log (SWEET FB 5 s lines).
#   tools/sunfish-fpsbench.sh TAG [SECONDS]
# Unlocks, then swipes between home pages for SECONDS; prints the fps lines
# logged during that window and their average.
cd "$(dirname "$0")/.." || exit 1
tag=$1 secs=${2:-30} L=../logs/usb-live.log
C() { python3 -I tools/flame-cmd.py "$@" >/dev/null 2>&1; }
C swipe 540 2330 540 1100 300; sleep 3
echo "=== bench $tag start $(date +%T)" >> "$L"
end=$((SECONDS + secs))
while [ $SECONDS -lt $end ]; do
	C swipe 900 1200 150 1200 250; sleep 0.6
	C swipe 150 1200 900 1200 250; sleep 0.6
done
sleep 6
echo "=== bench $tag end $(date +%T)" >> "$L"
sed -n "/=== bench $tag start/,/=== bench $tag end/p" "$L" | grep -a 'SWEET FB: 5s' | grep -oE '\([0-9.]+ fps\)|avg copy [0-9]+' | paste -d' ' - - | tee /dev/stderr |
	awk -v t="$tag" '{gsub(/[()fps ]/,"",$1); s+=$1; n++} END {if (n) printf "%s: %.1f fps average over %d samples\n", t, s/n, n}'
