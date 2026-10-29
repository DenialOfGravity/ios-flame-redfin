#!/bin/bash
# e2e-test.sh SRC.swtr [WORKDIR]: collector.py against fakephone.py on loopback (usb=127.0.0.2, wifi=127.0.0.3),
# every API endpoint with curl, trace round trips compared with cmp. Needs python3, curl; tools-claude/sweet-trace.py
# and sweet-prof.py next to this folder's parent (or in $TOOLS) for the analysis step.
set -u
H=$(cd "$(dirname "$0")" && pwd)
SRC=${1:?usage: e2e-test.sh SRC.swtr [WORKDIR]}
W=${2:-$(mktemp -d)}
TOOLS=${TOOLS:-$H/..}
API=http://127.0.0.1:18765
CTL=15199
FAIL=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAIL=$((FAIL + 1)); }
ctl() { python3 -c 'import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3); s.sendto(sys.argv[1].encode(),("127.0.0.1",int(sys.argv[2]))); print(s.recv(65536).decode())' "$1" $CTL; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
post() { curl -s -m ${3:-30} -X POST -H 'Content-Type: application/json' -d "$2" "$API$1"; }
waitfor() {	# SECS PYEXPR-on-/api/now
	local end=$(( $(date +%s) + $1 ))
	while [ "$(date +%s)" -lt $end ]; do
		[ "$(curl -s -m 3 $API/api/now | j "$2" 2>/dev/null)" = True ] && return 0; sleep 0.5; done; return 1; }
trace_wait() {	# SECS -> prints the newest finished trace's meta when no trace is running
	local end=$(( $(date +%s) + $1 ))
	while [ "$(date +%s)" -lt $end ]; do
		r=$(curl -s -m 3 $API/api/traces); [ "$(echo "$r" | j 'd["current"] is None')" = True ] && { echo "$r"; return 0; }; sleep 0.5; done; return 1; }

echo "workdir $W"
if python3 -c 'import socket; s=socket.socket(); s.settimeout(1); s.connect(("127.0.0.2",5150))' 2>/dev/null; then
	echo "something already listens on 127.0.0.2:5150 (an old fakephone?): stop it first"; exit 99; fi
mkdir -p "$W/tools-claude" "$W/agent" "$W/builds/xnu/ws-y-ram-aca60f47b8"
cp "$TOOLS"/sweet-trace.py "$TOOLS"/sweet-prof.py "$W/tools-claude/" 2>/dev/null || echo "(no analyzers in $TOOLS)"
echo 'klog PA 0x101d0ef08  (_sweet_log_total 0xfffffe0007d0ef08)' > "$W/builds/xnu/ws-y-ram-aca60f47b8/KLOG_PA.txt"
printf 'KNOWN GOOD\nKernel:   builds/xnu/ws-y-ram-aca60f47b8/ (branch ws-y-ram)\n' > "$W/KNOWN-GOOD.txt"
python3 "$H/collector.py" --root "$W" --make-key >/dev/null && [ -s "$W/agent/sweetmon.key" ] && ok "--make-key" || bad "--make-key"
python3 "$H/fakephone.py" --key-file "$W/agent/sweetmon.key" --trace "$SRC" --speedup 5 --ctl-port $CTL \
	--klog-dump "$W/fake-klog.txt" > "$W/fake.log" 2>&1 &
FP=$!
sleep 1
python3 "$H/collector.py" --root "$W" --http-port 18765 --usb-host 127.0.0.2 --poke-host 127.0.0.2 --poke-port 15141 \
	--ssh-port 1 --usb-probe-every 3 --ping-every 2 > "$W/collector.out" 2>&1 &
CP=$!
trap 'kill $FP $CP 2>/dev/null' EXIT
T0=$(date +%s)

# 1. connect, auth, samples, now.json
waitfor 15 'd.get("link",{}).get("authed") and d["link"]["via"]=="usb" and d.get("cpu") is not None' \
	&& ok "connect+auth over usb, sample in /api/now ($(( $(date +%s) - T0 )) s)" || bad "connect/auth"
sleep 6
python3 - "$W/logs/mon/now.json" <<'EOF' && ok "now.json: busy/MHz/temps/battery/gpu owners/procs/klog tags/self/link" || bad "now.json content"
import json, sys
d = json.load(open(sys.argv[1]))
assert len(d['cpu']['busy']) == 8, d['cpu']
assert d['cpu']['clusters']['prime']['mhz'] in (1612, 2400), d['cpu']['clusters']
assert d['temp']['max'] > 30 and d['temp_source'] == 'sysctl'
assert d['battery']['pct'] > 0 and d['battery']['ma'] < 0
assert d['gpu']['owners'][0]['name'] == 'backboardd'
assert d['procs']['by_cpu'][0]['name'] and d['procs']['by_wakeups']
assert d['klog']['top_tags'] and d['klog']['status'].startswith('ok')
assert d['self']['rss_mb'] > 0 and d['link']['rtt_ms'] is not None
assert d['hot'], d['hot']
print('  hot:', d['hot'])
EOF
ls "$W"/logs/mon/metrics-*.jsonl >/dev/null 2>&1 && [ "$(wc -l < "$W"/logs/mon/metrics-*.jsonl)" -ge 5 ] && ok "metrics jsonl ($(wc -l < "$W"/logs/mon/metrics-*.jsonl) lines)" || bad "metrics jsonl"

# 2. every GET endpoint
for p in / /api/now /api/status '/api/history?secs=60' '/api/klog?n=20' '/api/klog?n=5&grep=THERMAL' /api/traces; do
	c=$(curl -s -o "$W/get.out" -w '%{http_code}' "$API$p"); [ "$c" = 200 ] && ok "GET $p ($(stat -c %s "$W/get.out") bytes)" || bad "GET $p -> $c"
done
[ "$(curl -s "$API/api/klog?n=5&grep=THERMAL" | j 'all("THERMAL" in l for l in d["lines"]) and len(d["lines"])>0')" = True ] && ok "klog grep" || bad "klog grep"
[ "$(curl -s "$API/api/klog?grep=(" -o /dev/null -w '%{http_code}')" = 400 ] && ok "bad regex -> 400" || bad "bad regex"
timeout 4 curl -s -N "$API/api/stream" > "$W/sse.txt"; grep -q '^event: init' "$W/sse.txt" && grep -q '^event: sample' "$W/sse.txt" \
	&& grep -q '^event: klog' "$W/sse.txt" && ok "SSE /api/stream (init, sample, klog events)" || bad "SSE"
[ "$(post /api/cmd '{"cmd":"info"}' | j 'd["ok"] and d["msg"]=="fakephone"')" = True ] && ok "POST /api/cmd info" || bad "/api/cmd"
[ "$(post /api/cmd '{"cmd":"bogus"}' | j 'd["ok"]')" = False ] && ok "POST /api/cmd unknown -> ok false" || bad "/api/cmd bogus"

# 3. robustness: malformed frames
ctl badframe >/dev/null; sleep 2
[ "$(curl -s $API/api/now | j 'd["link"]["authed"]')" = True ] && grep -q "bad 'S' frame" "$W/logs/mon/collector.log" \
	&& ok "malformed frames logged, link stays up" || bad "malformed frames"

# 4. klog file + gap fill after a forced disconnect
BOOT=$(curl -s $API/api/now | j 'd["phone"]["boottime"]')
KF=$W/logs/mon/klog-$BOOT.txt
ctl crash testapp >/dev/null; ctl hot >/dev/null
sleep 2
ctl drop >/dev/null
sleep 0.3; ctl burst 30000 >/dev/null; ctl crash gapapp > /dev/null       # written while disconnected
waitfor 15 'd["link"]["authed"]' && sleep 3
python3 - "$KF" "$W/fake-klog.txt" <<'EOF' && ok "klog file == phone log after drop + gap fill (klog from POS)" || bad "klog gap fill"
import sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
n = min(len(a), len(b))
assert len(a) > 10000, len(a)
assert a[:n] == b[:n], 'differ at %d' % next(i for i in range(n) if a[i] != b[i])
assert len(b) - len(a) < 20000, (len(a), len(b))
assert b'CRASH gapapp' in a
print('  klog file %d bytes, phone %d (tail still in flight %d)' % (len(a), len(b), len(b) - len(a)))
EOF
grep -q 'klog from' "$W/logs/mon/collector.log" && ok "collector sent 'klog from POS' on reconnect" || bad "no klog from"
[ "$(curl -s $API/api/now | j 'd["thermal"]["level"]==1 and any(c["name"]=="testapp" for c in d["crashes"])')" = True ] \
	&& ok "thermal level + CRASH parsed" || bad "level/crash parse"
# lost bytes: ring overwritten while away (> 4 MiB)
ctl drop >/dev/null; sleep 0.2; ctl burst 4500000 >/dev/null
waitfor 15 'd["link"]["authed"] and d["klog"]["lost_bytes"]>0' && ok "ring overrun while disconnected -> lost bytes counted + marker" \
	&& grep -q 'sweetmon: .* bytes of kernel log lost' "$KF" || bad "lost bytes"

# 5. trace round trips
for mode in buffer stream; do
	t1=$(date +%s.%N)
	r=$(post /api/trace/start "{\"kind\":\"kdebug\",\"name\":\"t-$mode\",\"secs\":20,\"opts\":{\"mode\":\"$mode\",\"filter\":\"f\"}}")
	[ "$(echo "$r" | j 'd["ok"]')" = True ] || { bad "trace start $mode: $r"; continue; }
	sleep 2
	[ "$(curl -s $API/api/traces | j 'd["current"]["state"]')" = recording ] && ok "trace $mode recording" || bad "trace $mode not recording"
	post /api/trace/stop '{}' >/dev/null
	m=$(trace_wait 120) || { bad "trace $mode did not finish"; continue; }
	d=$(echo "$m" | j 'd["traces"][0]["dir"]')
	st=$(echo "$m" | j 'd["traces"][0]["state"]')
	if cmp -s "$SRC" "$W/logs/traces/$d/trace.swtr"; then ok "trace $mode: $d/trace.swtr identical to source ($(stat -c %s "$SRC") bytes), state $st, $(echo "$m" | j 'd["traces"][0]["transfer_mbps"]') MB/s, $(python3 -c "print('%.1f' % ($(date +%s.%N) - $t1))") s total"
	else bad "trace $mode: trace.swtr differs"; fi
	[ "$st" = done ] && [ -s "$W/logs/traces/$d/summary.json" ] && ok "trace $mode: sweet-trace.py --summary-json ran ($(stat -c %s "$W/logs/traces/$d/summary.json") bytes)" \
		|| bad "trace $mode analysis: state $st $(echo "$m" | j 'd["traces"][0]["error"]')"
done
# abort
post /api/trace/start '{"kind":"kdebug","name":"t-abort","secs":20}' >/dev/null; sleep 1
post /api/trace/stop '{"abort":true}' >/dev/null; m=$(trace_wait 10)
[ "$(echo "$m" | j 'd["traces"][0]["state"]')" = aborted ] && ok "trace abort" || bad "trace abort"
# phone ends it by itself at secs
post /api/trace/start '{"kind":"kdebug","name":"t-secs","secs":3}' >/dev/null
m=$(trace_wait 60); [ "$(echo "$m" | j 'd["traces"][0]["state"]')" = done ] && ok "trace ends at secs without stop" || bad "trace secs"
# kernel profiler: poke -> SWEET PROF start/done in klog -> pmem -> sweet-prof.py
r=$(post /api/trace/start '{"kind":"prof","name":"p1","secs":4,"opts":{"target":"backboardd","hz":1000}}')
[ "$(echo "$r" | j 'd["ok"]')" = True ] || bad "prof start: $r"
m=$(trace_wait 90)
pd=$(echo "$m" | j 'd["traces"][0]["dir"]')
[ "$(echo "$m" | j 'd["traces"][0]["state"]')" = done ] && head -c 7 "$W/logs/traces/$pd/prof.bin" | grep -q SWPROF1 \
	&& grep -q 'samples' "$W/logs/traces/$pd/report.txt" && ok "prof: poke -> SWEET PROF lines -> pmem -> prof.bin -> sweet-prof.py report" \
	|| bad "prof: $(echo "$m" | j 'd["traces"][0]')"
# prof stop early
post /api/trace/start '{"kind":"prof","name":"p2","secs":60,"opts":{"target":"SpringBoard"}}' >/dev/null; sleep 3
post /api/trace/stop '{}' >/dev/null; m=$(trace_wait 60)
[ "$(echo "$m" | j 'd["traces"][0]["state"]')" = done ] && ok "prof stopped early (p prof stop)" || bad "prof stop: $(echo "$m" | j 'd["traces"][0]')"
for f in summary.json report.txt meta.json; do c=$(curl -s -o /dev/null -w '%{http_code}' "$API/api/traces/$(ls -t "$W/logs/traces" | grep t-buffer | head -1)/$f"); [ "$c" = 200 ] && ok "GET /api/traces/DIR/$f" || bad "GET trace file $f $c"; done

# 6. speed test
r=$(post /api/speed '{"mb":32}' 120)
[ "$(echo "$r" | j 'd["ok"] and d["bytes"]==32*1048576')" = True ] && ok "speed 32 MiB: $(echo "$r" | j 'd["mbps"]') MB/s over loopback" || bad "speed: $r"

# 7. frames on/off
post /api/frames '{"on":true}' >/dev/null
waitfor 10 'd.get("frames") is not None and d["frames_on"]' && ok "frames on -> F frames in now.json" || bad "frames on"
post /api/frames '{"on":false}' >/dev/null; sleep 4
[ "$(curl -s $API/api/now | j 'd["frames"] is None and not d["frames_on"]')" = True ] && ok "frames off" || bad "frames off"

# 8. rate + klog-pa
[ "$(post /api/rate '{"ms":500}' | j 'd["ok"]')" = True ] && ok "POST /api/rate" || bad "rate"
[ "$(post /api/klog-pa '{"pa":"0xdeadbeef00"}' | j '"refused" in d["msg"]')" = True ] && ok "klog-pa wrong PA -> refused message, falls back" || bad "klog-pa wrong"
[ "$(post /api/klog-pa '{"pa":"auto"}' | j 'd["msg"].startswith("ok")')" = True ] && ok "klog-pa auto (KNOWN-GOOD kernel's KLOG_PA.txt)" || bad "klog-pa auto"

# 9. link switching: wifi, back to usb, auto fallback when USB dies, auto back to USB
post /api/link '{"link":"wifi"}' >/dev/null
waitfor 15 'd["link"]["authed"] and d["link"]["via"]=="wifi" and d["link"]["host"]=="127.0.0.3"' && ok "link wifi (address learned from hello en0)" || bad "link wifi"
post /api/link '{"link":"usb"}' >/dev/null
waitfor 15 'd["link"]["authed"] and d["link"]["via"]=="usb"' && ok "link usb" || bad "link usb"
post /api/link '{"link":"auto"}' >/dev/null; sleep 1
ctl 'down usb' >/dev/null
waitfor 20 'd["link"]["authed"] and d["link"]["via"]=="wifi"' && ok "auto: USB gone -> Wi-Fi" || bad "auto fallback"
ctl 'up usb' >/dev/null
waitfor 25 'd["link"]["authed"] and d["link"]["via"]=="usb"' && ok "auto: USB back -> USB" || bad "auto back to usb"
[ "$(post /api/link '{"link":"x"}' | j 'd["ok"]')" = False ] && ok "bad link -> 400" || bad "bad link"

# 10. auth refused with a wrong key; new boot -> new klog file
cp "$W/agent/sweetmon.key" "$W/key.save"; echo 00112233445566778899aabbccddeeff > "$W/agent/sweetmon.key"; ctl drop >/dev/null
waitfor 12 '"auth refused" in d["link"]["msg"] and not d["link"]["authed"]' && ok "wrong key -> auth refused shown" || bad "wrong key"
cp "$W/key.save" "$W/agent/sweetmon.key"
waitfor 25 'd["link"]["authed"]' && ok "right key again -> reconnected" || bad "reconnect after key fix"
ctl reboot >/dev/null
waitfor 20 'd["link"]["authed"] and d["phone"]["boottime"]!='"$BOOT" && sleep 2 && \
	[ "$(ls "$W"/logs/mon/klog-*.txt | wc -l)" = 2 ] && ok "phone reboot -> new klog-<boot>.txt" || bad "reboot klog file"

# 11. ctl client (the agent's mon actions)
export SWEETMON_API=$API
python3 "$H/collector.py" ctl status > "$W/ctl.txt" && python3 "$H/collector.py" ctl snap >> "$W/ctl.txt" && python3 "$H/collector.py" ctl traces >> "$W/ctl.txt" \
	&& ok "ctl status/snap/traces" || bad "ctl"
python3 "$H/collector.py" ctl trace c1 kdebug 2 mode=buffer >/dev/null && python3 "$H/collector.py" ctl wait 60 >/dev/null && ok "ctl trace + wait" || bad "ctl trace"
kill $FP; sleep 3
[ "$(curl -s $API/api/now | j 'not d["link"]["authed"]')" = True ] && ok "phone gone -> collector up, link down" || bad "phone gone"
grep -c ERROR "$W/logs/mon/collector.log" | sed 's/^/collector.log ERROR lines: /'
grep -q Traceback "$W/collector.out" && bad "collector stderr has a traceback" || ok "no traceback in collector stderr"
echo "total $(( $(date +%s) - T0 )) s, failures $FAIL"
exit $FAIL
