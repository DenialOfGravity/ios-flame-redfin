#!/usr/bin/env bash
# bt-spike.sh: what does iOS 16.7's Bluetooth stack (bluetoothd, BlueTool, wirelessproxd, ...) expect from the
# hardware? Run in WSL against the iOS root image (read-only), optionally with the D22 DeviceTree and kernelcache.
# Prints one compact report (also saved to bt-spike-report.txt) for docs/redfin/qol-plan.md WS-B stage 2.
#
#   tools-claude/bt-spike.sh ROOT [--adt DeviceTree.d22ap.im4p] [--kc kernelcache] [--out FILE] [--max N]
#
# ROOT = a mounted root (directory) or the root image file (mounted read-only at /mnt/bt-spike, needs sudo and
# hfsplus). --adt: raw ADT or IM4P (tools/adt.py; lzfse needed if compressed). --kc: a decompressed kernelcache
# Mach-O or IM4P (lzfse). Needs python3, grep, strings (binutils). Nothing is written to ROOT.
# Sections: launchd jobs, binaries + linked libraries + entitlements, strings by topic (kernel-control names,
# /dev nodes, power/wake lines, IOKit classes, ADT property names, firmware files, Broadcom/vendor commands,
# transports, errors) in the daemons and the dyld shared cache, firmware dirs, ADT nodes, kernelcache kexts.
set -u
ROOT=${1:-}
[ -n "$ROOT" ] || { sed -n '2,15p' "$0"; exit 2; }
shift
ADT= KC= OUT=bt-spike-report.txt MAX=25
while [ $# -gt 0 ]; do
	case $1 in
	--adt) ADT=$2; shift 2 ;;
	--kc) KC=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--max) MAX=$2; shift 2 ;;
	*) echo "unknown option $1"; exit 2 ;;
	esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
MNT=
if [ -f "$ROOT" ]; then
	MNT=/mnt/bt-spike
	sudo mkdir -p $MNT && sudo mount -o loop,ro -t hfsplus "$ROOT" $MNT || { echo "mount failed"; exit 1; }
	trap 'sudo umount $MNT' EXIT
	ROOT=$MNT
fi
[ -d "$ROOT/System/Library" ] || { echo "$ROOT does not look like an iOS root"; exit 1; }

exec > >(tee "$OUT") 2>&1
export LC_ALL=C
sec() { printf '\n==== %s\n' "$*"; }

sec "bt-spike $(date -u +%F) root=$ROOT"
cat "$ROOT/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null | tr -d '\n\t' |
	grep -o '<key>ProductBuildVersion</key><string>[^<]*\|<key>ProductVersion</key><string>[^<]*' | sed 's/<[^>]*>/ /g'

# ---------------------------------------------------------------- launchd
sec "launchd jobs mentioning Bluetooth"
python3 - "$ROOT" <<'EOF'
import glob, os, plistlib, re, sys
root = sys.argv[1]
pat = re.compile(rb'blue|BTLE|wirelessprox|BlueTool|bluetooth', re.I)
dirs = ['System/Library/LaunchDaemons', 'System/Library/LaunchAgents', 'System/Library/NanoLaunchDaemons',
        'Library/LaunchDaemons', 'System/Library/xpc/launchd.plist']
files = []
for d in dirs:
    p = os.path.join(root, d)
    files += sorted(glob.glob(p + '/*.plist')) if os.path.isdir(p) else ([p] if os.path.isfile(p) else [])
def show(name, j):
    keys = ['Label', 'Program', 'ProgramArguments', 'UserName', 'GroupName', 'RunAtLoad', 'KeepAlive',
            'POSIXSpawnType', 'LaunchOnlyOnce', 'EnablePressuredExit', 'ThrottleInterval', 'ProcessType']
    out = {k: j[k] for k in keys if k in j}
    if 'MachServices' in j: out['MachServices'] = sorted(j['MachServices'])
    if 'LaunchEvents' in j: out['LaunchEvents'] = {k: sorted(v) if isinstance(v, dict) else v for k, v in j['LaunchEvents'].items()}
    if 'Sockets' in j: out['Sockets'] = sorted(j['Sockets'])
    for k in ('EnvironmentVariables', 'StandardErrorPath', 'StandardOutPath'):
        if k in j: out[k] = j[k]
    print(f'-- {name}')
    for k, v in out.items():
        s = repr(v)
        print(f'   {k}: {s[:400]}{"..." if len(s) > 400 else ""}')
for f in files:
    raw = open(f, 'rb').read()
    if not pat.search(raw):
        continue
    try:
        pl = plistlib.loads(raw)
    except Exception as e:
        print(f'-- {f}: unreadable ({e})'); continue
    if f.endswith('launchd.plist'):   # the cache of every job (iOS 16: xpc/launchd.plist)
        for sect in pl.values():
            if isinstance(sect, dict):
                for name, j in sect.items():
                    if isinstance(j, dict) and pat.search(repr(j).encode()):
                        show(f'launchd.plist {name}', j)
    else:
        show(os.path.relpath(f, root), pl)
EOF

# ---------------------------------------------------------------- binaries
sec "Bluetooth binaries"
BINS=$(find "$ROOT/usr" "$ROOT/System/Library/CoreServices" "$ROOT/System/Library/PrivateFrameworks" \
	"$ROOT/System/Library/Frameworks" -xdev -type f \( -name bluetoothd -o -name BlueTool -o -name wirelessproxd \
	-o -name bluetoothuserd -o -name 'BTLEServer*' -o -name BTServer -o -name 'BlueTool*' -o -name bluetoothaudiod \
	-o -name 'BTAvrcp*' -o -name 'MobileBluetooth' -o -name 'BluetoothManager' -o -name CoreBluetooth \) 2>/dev/null | sort)
for b in $BINS; do printf '%10s %s\n' "$(stat -c %s "$b")" "${b#$ROOT}"; done
python3 - $BINS <<'EOF'
import struct, sys, plistlib
def slices(buf):
    m = struct.unpack_from('>I', buf, 0)[0]
    if m in (0xcafebabe, 0xcafebabf):
        n = struct.unpack_from('>I', buf, 4)[0]
        for i in range(n):
            if m == 0xcafebabe:
                cpu, sub, off, size, al = struct.unpack_from('>5I', buf, 8 + 20 * i)
            else:
                cpu, sub, off, size, al, _ = struct.unpack_from('>IIQQII', buf, 8 + 32 * i)
            yield cpu, buf[off:off + size]
    else:
        yield None, buf
def info(sl):
    if struct.unpack_from('<I', sl, 0)[0] != 0xfeedfacf:
        return None
    cpu, sub, ft, ncmds, sz, flags, _ = struct.unpack_from('<7I', sl, 4)
    off, libs, ents = 32, [], None
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', sl, off)
        if cmd in (0xc, 0x80000018, 0x8000001f, 0x80000023):
            no = struct.unpack_from('<I', sl, off + 8)[0]
            libs.append(sl[off + no:off + cs].split(b'\0')[0].decode(errors='replace'))
        elif cmd == 0x1d:
            do, ds = struct.unpack_from('<II', sl, off + 8)
            blob = sl[do:do + ds]
            if len(blob) >= 12 and struct.unpack_from('>I', blob, 0)[0] == 0xfade0cc0:
                cnt = struct.unpack_from('>I', blob, 8)[0]
                for i in range(cnt):
                    t, o = struct.unpack_from('>II', blob, 12 + 8 * i)
                    mg, ln = struct.unpack_from('>II', blob, o)
                    if mg == 0xfade7171:
                        ents = blob[o + 8:o + ln]
        off += cs
    return cpu, sub, libs, ents
for path in sys.argv[1:]:
    try:
        buf = open(path, 'rb').read()
    except Exception as e:
        print(f'-- {path}: {e}'); continue
    for cpu, sl in slices(buf):
        r = info(sl)
        if not r:
            continue
        cpu, sub, libs, ents = r
        print(f'-- {path.split("/")[-1]} (cpu {cpu:#x}/{sub & 0xff:#x}) {path}')
        print('   links: ' + ', '.join(l.split('/')[-1] for l in libs))
        if ents:
            try:
                e = plistlib.loads(ents)
                for k in sorted(e):
                    v = repr(e[k])
                    print(f'   ent {k} = {v[:200]}{"..." if len(v) > 200 else ""}')
            except Exception as ex:
                print(f'   entitlements unreadable: {ex}')
        else:
            print('   (no entitlements blob)')
        break
EOF

# ---------------------------------------------------------------- strings
CACHES=$(find "$ROOT/System/Library/Caches/com.apple.dyld" "$ROOT/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld" \
	"$ROOT/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld" -maxdepth 1 -type f -name 'dyld_shared_cache_arm64*' \
	! -name '*.map' ! -name '*.symbols' 2>/dev/null | sort)
sec "dyld shared caches: $(echo $CACHES | wc -w) files"
# topic|regex (ERE, applied to printable runs)
TOPICS='kernel-control names|com\.apple\.[A-Za-z0-9._-]*(uart|UART|serial|bluetooth|Bluetooth|hci|HCI)[A-Za-z0-9._-]*
/dev nodes|/dev/[A-Za-z0-9._%-]*
power and wake lines|[A-Za-z0-9_-]*(btwake|btreset|btpoweroff|bt-wake|bt_wake|host-wake|host_wake|BT_REG_ON|bt-reg-on|reg-on|BTPower|btpower|BTReset|wlan-bt|bt-pcie)[A-Za-z0-9_-]*
IOKit classes|(Apple|IO)[A-Za-z0-9]*(Bluetooth|BT|UART|Uart|Serial|Converged|OLY|Olympic|BCM|Bcm|HCI|Hci)[A-Za-z0-9]*
ADT properties|(bluetooth|bt|uart)-[a-z0-9-]{3,}
firmware files|[A-Za-z0-9/._-]*(\.hcd|\.ptb|\.trx|\.bin|\.dfu|\.im4p|patchram|PatchRAM|PatchRam|firmware/bluetooth)[A-Za-z0-9/._-]*
vendor names|(Broadcom|BRCM|BCM43[0-9A-Za-z]*|BCM4[0-9]{3}[A-Za-z0-9]*|Cypress|Infineon|Marconi|Olympic|Lumberjack|Apple Bluetooth|USI|Murata|Qualcomm|QCA|Atheros)
transports|[A-Za-z]*(Transport|transport|H4|H5|BCSP|PCIe|SDIO|HCIUART|hciuart)[A-Za-z0-9]*
vendor HCI commands|(0x[Ff][Cc][0-9A-Fa-f]{2}|[Vv]endor[A-Za-z ]{0,20}[Cc]ommand[A-Za-z ]{0,20}|WriteBDADDR|SetBaud[A-Za-z]*|[Ll]aunch[Rr]am|[Dd]ownload[A-Za-z]*[Mm]ini[Dd]river)
errors|([Ff]ailed|[Uu]nable|[Cc]ould not|[Cc]annot|[Tt]imed out)[^\"]{0,40}(open|find|power|reset|transport|uart|UART|device|chip|firmware|controller)[^\"]{0,60}'
grep_topics() {	# FILE...
	echo "$TOPICS" | while IFS='|' read -r name re; do
		local hits
		hits=$(strings -a -n 5 "$@" 2>/dev/null | grep -o -E "$re" | sort | uniq -c | sort -rn | head -"$MAX")
		[ -n "$hits" ] || continue
		echo "-- $name"
		echo "$hits" | sed 's/^/   /'
	done
}
for b in $BINS; do
	case $(basename "$b") in bluetoothd|BlueTool|wirelessproxd|bluetoothuserd|BTLEServer*) ;; *) continue ;; esac
	sec "strings: ${b#$ROOT}"
	grep_topics "$b"
done
if [ -n "$CACHES" ]; then
	sec "strings: dyld shared cache (all subcaches; slow)"
	# only strings near Bluetooth context: whole-cache runs of the same topics would drown in other frameworks
	strings -a -n 6 $CACHES 2>/dev/null | grep -E -i 'blue|uart|hci|btwake|btreset|bt-|bcm|olympic|marconi|transport|patchram|\.hcd' \
		> /tmp/bt-spike-cache.txt
	echo "($(wc -l < /tmp/bt-spike-cache.txt) Bluetooth-ish strings)"
	grep_topics /tmp/bt-spike-cache.txt
	echo "-- every kernel-control name candidate (com.apple.*uart*/*bluetooth*, exact)"
	grep -o -E '^com\.apple\.[A-Za-z0-9._-]*(uart|bluetooth|Bluetooth)[A-Za-z0-9._-]*$' /tmp/bt-spike-cache.txt | sort -u | head -60 | sed 's/^/   /'
	echo "-- /dev paths (exact)"
	grep -o -E '^/dev/[A-Za-z0-9._%-]+$' /tmp/bt-spike-cache.txt | sort -u | head -60 | sed 's/^/   /'
	rm -f /tmp/bt-spike-cache.txt
fi

# ---------------------------------------------------------------- firmware on the root
sec "firmware directories"
for d in usr/share/firmware usr/share/firmware/bluetooth usr/share/firmware/wifi System/Library/Bluetooth \
	System/Library/PrivateFrameworks/MobileBluetooth.framework System/Library/Frameworks/CoreBluetooth.framework; do
	[ -e "$ROOT/$d" ] || continue
	echo "-- /$d"
	ls -la "$ROOT/$d" 2>/dev/null | head -40 | sed 's/^/   /'
done
find "$ROOT/usr/share" "$ROOT/System/Library" -xdev \( -iname '*.hcd' -o -iname '*bluetooth*.plist' -o -iname '*BTFW*' \) 2>/dev/null |
	head -40 | sed "s|^$ROOT||;s/^/   /"

# ---------------------------------------------------------------- ADT
if [ -n "$ADT" ]; then
	sec "ADT nodes: uart / bluetooth / wlan ($ADT)"
	python3 - "$REPO/tools" "$ADT" <<'EOF'
import re, sys
sys.path.insert(0, sys.argv[1])
import adt
root, _ = adt.parse(adt.load(sys.argv[2]))
pat = re.compile(r'uart|bluetooth|^bt|wlan|olympic|marconi|serial', re.I)
def walk(n, path):
    p = path + '/' + n.name
    if pat.search(n.name) or any(pat.search(k) and k != 'name' for k, _, _ in n.props if k.startswith(('bluetooth', 'bt-'))):
        print(f'-- {p}')
        for k, f, v in n.props:
            if k != 'name':
                print(f'   {k}{" [placeholder]" if f else ""} = {adt.fmt(v)}')
    for c in n.children:
        walk(c, p)
walk(root, '')
EOF
fi

# ---------------------------------------------------------------- kernelcache
if [ -n "$KC" ]; then
	sec "kernelcache: Bluetooth / UART kexts and classes ($KC)"
	KCF=$KC
	if head -c 16 "$KC" | grep -q IM4P; then
		python3 - "$REPO/tools" "$KC" /tmp/bt-spike-kc <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import adt
open(sys.argv[3], 'wb').write(adt.load(sys.argv[2]))
EOF
		KCF=/tmp/bt-spike-kc
	fi
	echo "-- bundle ids"
	strings -a -n 8 "$KCF" | grep -o -E 'com\.apple\.(driver|iokit|kext)\.[A-Za-z0-9._-]*(Bluetooth|BT|UART|Uart|Serial|Converged|OLY|BCM|HCI)[A-Za-z0-9._-]*' |
		sort -u | head -60 | sed 's/^/   /'
	echo "-- classes"
	strings -a -n 8 "$KCF" | grep -o -E '^(Apple|IO)[A-Za-z0-9]*(Bluetooth|UART|Uart|Serial|Converged|OLY|BCM|HCI)[A-Za-z0-9]*$' |
		sort -u | head -80 | sed 's/^/   /'
	echo "-- kernel-control names"
	strings -a -n 8 "$KCF" | grep -o -E 'com\.apple\.[A-Za-z0-9._-]*(uart|bluetooth|Bluetooth)[A-Za-z0-9._-]*' | sort -u | head -40 | sed 's/^/   /'
	[ "$KCF" != "$KC" ] && rm -f "$KCF"
fi
sec "done: report in $OUT"
