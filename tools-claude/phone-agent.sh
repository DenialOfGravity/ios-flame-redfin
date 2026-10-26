#!/bin/bash
# phone-agent: lets Claude drive the phone from this WSL session through the shared project folder.
#
# Start once per session, in WSL:   bash /mnt/c/ClaudeProjects/iOS_Pixel5/tools-claude/phone-agent.sh
# (asks for your sudo password once, for the USB network; Ctrl-C stops it).
#
# Claude writes one request per file into  C:\ClaudeProjects\iOS_Pixel5\agent\inbox\NAME.req  and
# reads the answer from  agent\outbox\NAME.out. Only the actions below exist; there is no general
# shell. Nothing here flashes anything: images are only ever started from RAM (fastboot boot), and
# the file server has no delete.
#
#   status                     usbipd list, fastboot/adb devices, the phone's USB network
#   attach                     usbipd attach --wsl for the phone (iOS USB Ethernet, fastboot, TWRP adb)
#   net                        USB network up (192.168.7.1) and the live kernel log -> logs/live-*.txt
#   boot NAME                  fastboot boot NAME/redfin-NAME.img (checked against its .sha256)
#   boot-twrp                  fastboot boot twrp-3.7.0_11-0-redfin.img
#   to-fastboot                the running iOS kernel resets into fastboot (flame-cmd.py reboot)
#   adb-to-fastboot            TWRP: adb reboot bootloader
#   files VERB ARGS            tools/flame-files.py VERB ARGS   (VERB: put get mkdir read chmod link)
#   poke TEXT                  tools/flame-cmd.py TEXT          (the phone's command server)
#   install-audio NAME         tools/redfin-install-audio.sh NAME
#   klog [PA]                  the kernel log ring -> logs/klog.txt (tools-claude/klog.py)
#   twrp-pull                  TWRP: /vendor mounted read-only, ADSP + amplifier firmware and the audio
#                              configuration copied to ios-redfin-tree/ios-redfin/recon/fw-adsp
#   twrp-pull-sensors          TWRP: /vendor/etc/sensors, /vendor/dsp, /vendor/etc/acdbdata and /sys/devices/soc0 (read
#                              only) to ios-redfin-tree/ios-redfin/recon/fw-adsp/sensors-*.tar
#   twrp-pull-camera           TWRP: listings of /vendor/lib64/camera and /vendor/etc/camera, and copies (read only) of the
#                              sensor module files (*sensormodule*) and any actuator/OIS/EEPROM/flash files, /vendor/etc/camera,
#                              and the live DT's camera nodes (qcom,cam-sensor@N, qcom,actuator@N, qcom,ois@N, qcom,eeprom@N,
#                              qcom,camera-flash@N), to ios-redfin-tree/ios-redfin/recon/camera. (On redfin the actuator, OIS
#                              and EEPROM data are inside the sensormodule files: tools/redfin-camsensor.py -a.)
#   twrp-pull-qol              TWRP: BT firmware (crbtfw/crnv), CS35L41/rt5514 firmware, /vendor/etc/bluetooth + audio xml,
#                              the persist partition (sensor/camera/audio calibration), camera com.qti.tuned, BT DT nodes -> recon/fw-qol
#   twrp-pull-log              TWRP: the last 8 MiB of userdata (holds the persistent kernel log; read only) -> logs/sweetlog-<time>.bin
#   git-pull                   git pull in the repo
#   reload                     start this script again (after Claude updated it)
#   ssh-key                    make the key for the phone (~/.ssh/redfin-claude) and put its public half in agent/stage
#   phone CMD                  run CMD on the phone over SSH (dropbear on 192.168.7.2): the phone only, never this PC
#
# Local builds (tools-claude/localbuild, in WSL as this user, never root; output and logs in builds/):
#   build-env                  what the build host has (cores, memory, disk, toolchain, SDKs)
#   build-apt                  sudo apt-get install the fixed package list below (the only step that uses sudo)
#   build-setup STEP           background: lb.sh setup STEP  (toolchain into ~/redfin-build/toolchain)
#   build TARGET [REF]         background: lb.sh build TARGET REF  (TARGET shim|userland|metal2|xnu, REF a branch
#                              or commit of DenialOfGravity/ios-flame-redfin, default redfin-qol)
#   build-jobs                 running local builds;   build-kill  stops them all
#   build-diag                 run localbuild/diag.sh (a throwaway inspection script Claude writes; foreground)
set -uo pipefail
P=/mnt/c/ClaudeProjects/iOS_Pixel5
REPO=${REPO:-$HOME/ios-redfin}
IN=$P/agent/inbox OUT=$P/agent/outbox
mkdir -p "$IN" "$OUT" "$P/logs"
USBIPD=$(command -v usbipd.exe || ls "/mnt/c/Program Files/usbipd-win/usbipd.exe" 2>/dev/null || true)
# The Windows tools first: they see the phone without passing it to WSL (fastboot and TWRP modes).
FB=$(command -v fastboot.exe || command -v fastboot || true)
ADB=$(command -v adb.exe || command -v adb || true)

echo "phone-agent: repo $REPO, fastboot ${FB:-none}, adb ${ADB:-none}, usbipd ${USBIPD:-none}"
sudo -v || { echo "need sudo for the USB network"; exit 1; }
( while sleep 50; do sudo -n true 2>/dev/null || exit; done ) &
KEEP=$!
LIVEPIDF=/tmp/phone-agent-live.pid

live_running() { [ -f $LIVEPIDF ] && kill -0 "$(cat $LIVEPIDF)" 2>/dev/null; }

live_start() {
	live_running && return 0
	local log=$P/logs/live-$(date +%Y%m%d-%H%M%S).txt
	python3 -I -u -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 5140))
with open(sys.argv[1], "ab") as f:
    while True:
        d, _ = s.recvfrom(65536); f.write(d); f.flush()
' "$log" &
	echo $! > $LIVEPIDF
	echo "live log -> $log"
}

# In the background, all the time: the iOS USB Ethernet attached to WSL whenever the phone shows it
# (usbipd attach, as after "usbipd attach --wsl" in PowerShell), its address set, the live log running.
auto_usb() {
	sudo modprobe vhci_hcd 2>/dev/null; sudo modprobe cdc_ether 2>/dev/null
	while true; do
		if [ -n "$USBIPD" ]; then
			"$USBIPD" list 2>/dev/null | tr -d '\r' | awk '/^[0-9]+-[0-9]+/ && /1209:0001/ && /Shared|Not attached/ && !/Attached/ {print $1}' | while read -r b; do
				echo "$(date +%T) auto: attaching the phone's USB Ethernet ($b)"
				"$USBIPD" attach --wsl --busid "$b" 2>&1 | tr -d '\r' | head -2
			done
		fi
		for d in /sys/class/net/*; do
			[[ $(cat "$d/address" 2>/dev/null) == 02:00:5e:77:ee:01 ]] || continue
			ifc=${d##*/}
			if ! ip -4 addr show dev "$ifc" | grep -q 192.168.7.1/; then
				sudo -n ip addr flush dev "$ifc"; sudo -n ip addr add 192.168.7.1/24 dev "$ifc"; sudo -n ip link set "$ifc" up
				echo "$(date +%T) auto: $ifc up (192.168.7.1)"
			fi
			live_start
		done
		sleep 3
	done
}
auto_usb &
AUTO=$!
trap 'kill $KEEP $AUTO 2>/dev/null; live_running && kill "$(cat $LIVEPIDF)"; echo "phone-agent: stopped"; exit 0' INT TERM

attach() {
	[ -n "$USBIPD" ] || { echo "no usbipd.exe"; return 1; }
	"$USBIPD" list | tr -d '\r' | awk '/^[0-9]+-[0-9]+/ && /1209:0001/ && !/Attached/ {print $1}' | while read -r b; do
		echo "attach $b"; "$USBIPD" attach --wsl --busid "$b" 2>&1 | tr -d '\r'
	done
	sleep 3
	"$USBIPD" list | tr -d '\r' | grep -E '1209:0001|18d1:' || echo "(no phone in usbipd list)"
}

net() {
	sudo modprobe vhci_hcd 2>/dev/null; sudo modprobe cdc_ether
	local ifc=
	for _ in $(seq 30); do
		for d in /sys/class/net/*; do
			[[ $(cat "$d/address" 2>/dev/null) == 02:00:5e:77:ee:01 ]] && { ifc=${d##*/}; break 2; }
		done
		sleep 1
	done
	[ -n "$ifc" ] || { echo "no phone USB Ethernet (is it attached?)"; return 1; }
	sudo ip addr flush dev "$ifc"; sudo ip addr add 192.168.7.1/24 dev "$ifc"; sudo ip link set "$ifc" up
	echo "$ifc up"
	ping -c 2 -W 2 192.168.7.2
	live_start
}

# fastboot.exe / adb.exe (Windows) take Windows paths
winpath() { case $1 in *.exe) wslpath -w "$2";; *) echo "$2";; esac; }

LB=$P/tools-claude/localbuild/lb.sh
BUILD_APT="build-essential pkg-config ninja-build python3 python3-dev python3-venv python3-pip xz-utils libssl-dev
 zlib1g-dev libbsd-dev uuid-dev llvm llvm-dev libclang-dev clang lld device-tree-compiler git patch flex bison bzip2
 cpio rsync curl wget ca-certificates tcsh unifdef cmake mtools lz4 m4 jq file libxml2-dev glslang-tools meson
 libplist-dev libplist-2.0-dev ldid rustup ruby"
lb_bg() {	# KIND ARGS...: start lb.sh detached, log in builds/logs
	mkdir -p "$P/builds/logs"
	local log=$P/builds/logs/$1-$(echo "${*:2}" | tr ' /' '__')-$(date +%Y%m%d-%H%M%S).log
	setsid nohup bash "$LB" "$@" </dev/null >"$log" 2>&1 &
	echo "started pid $! -> ${log#$P/}"
}

ok_name() { [[ $1 =~ ^r[0-9a-z]+(-[0-9a-z]+)*$ ]]; }

run() {	# one request line
	read -r act rest <<<"$1"
	case $act in
	status)
		[ -n "$USBIPD" ] && "$USBIPD" list | tr -d '\r'
		[ -n "$FB" ] && { echo "fastboot devices:"; timeout 10 "$FB" devices; }
		[ -n "$ADB" ] && { echo "adb devices:"; timeout 10 "$ADB" devices; }
		ip -br addr | grep -E '192\.168\.7\.' || echo "(no phone network)"
		ping -c 1 -W 2 192.168.7.2 >/dev/null && echo "phone answers on 192.168.7.2" || echo "phone not reachable on 192.168.7.2"
		live_running && echo "live log running" || echo "live log not running";;
	attach) attach;;
	net) net;;
	boot)
		ok_name "$rest" || { echo "bad name"; return 1; }
		local d=$P/$rest img=$P/$rest/redfin-$rest.img
		[ -f "$img" ] || { echo "no $img"; return 1; }
		(cd "$d" && sha256sum -c "redfin-$rest.sha256" 2>&1 | grep "redfin-$rest.img") || { echo "checksum failed"; return 1; }
		timeout 120 "$FB" boot "$(winpath "$FB" "$img")";;
	boot-twrp) timeout 120 "$FB" boot "$(winpath "$FB" "$P/twrp-3.7.0_11-0-redfin.img")";;
	to-fastboot) (cd "$REPO" && timeout 20 python3 -I tools/flame-cmd.py --wait 2 reboot);;
	adb-to-fastboot) timeout 20 "$ADB" -d reboot bootloader;;
	files)
		read -r verb args <<<"$rest"
		case $verb in put|get|mkdir|read|chmod|link) ;; *) echo "verb not allowed"; return 1;; esac
		# shellcheck disable=SC2086
		(cd "$REPO" && timeout 300 python3 -I tools/flame-files.py "$verb" $args);;
	poke) (cd "$REPO" && timeout 30 python3 -I tools/flame-cmd.py --wait 3 "$rest");;
	install-audio)
		ok_name "$rest" || { echo "bad name"; return 1; }
		(cd "$REPO" && timeout 300 bash tools/redfin-install-audio.sh "$P/$rest");;
	klog) (cd "$REPO" && timeout 300 python3 "$P/tools-claude/klog.py" $rest);;
	twrp-pull)
		local dst=$P/ios-redfin-tree/ios-redfin/recon/fw-adsp
		mkdir -p "$dst"
		timeout 30 "$ADB" shell 'mount | grep -q " /vendor " || mount -o ro /vendor' ; timeout 10 "$ADB" shell 'mount | grep " /vendor "'
		timeout 120 "$ADB" exec-out 'cd /vendor/firmware && ls adsp* *cs35l41* *.jsn 2>/dev/null | xargs tar cf -' > "$dst/adsp-fw.tar"
		timeout 60 "$ADB" exec-out 'cd /vendor/etc && ls mixer_paths*.xml audio_platform_info*.xml audio_policy*.xml 2>/dev/null | xargs tar cf -' > "$dst/audio-etc.tar"
		ls -la "$dst"; tar tvf "$dst/adsp-fw.tar" | head -40; tar tvf "$dst/audio-etc.tar";;
	twrp-pull-sensors)
		local dst=$P/ios-redfin-tree/ios-redfin/recon/fw-adsp
		mkdir -p "$dst"
		timeout 30 "$ADB" shell 'mount | grep -q " /vendor " || mount -o ro /vendor'
		timeout 120 "$ADB" exec-out 'cd /vendor/etc && tar cf - sensors' > "$dst/sensors-etc.tar"
		timeout 300 "$ADB" exec-out 'cd /vendor && tar cf - dsp' > "$dst/sensors-dsp.tar"
		timeout 120 "$ADB" exec-out 'cd /vendor/etc && tar cf - acdbdata' > "$dst/sensors-acdb.tar"
		timeout 60 "$ADB" exec-out 'cd /sys/devices/soc0 && for f in *; do [ -f "$f" ] && echo "$f=$(cat $f 2>/dev/null)"; done' > "$dst/soc0.txt"
		ls -la "$dst"; tar tf "$dst/sensors-etc.tar" | head -20; tar tf "$dst/sensors-etc.tar" | wc -l; cat "$dst/soc0.txt";;
	twrp-pull-camera)
		local dst=$P/ios-redfin-tree/ios-redfin/recon/camera
		mkdir -p "$dst"
		timeout 30 "$ADB" -d shell 'mount | grep -q " /vendor " || mount -o ro /vendor'
		timeout 60 "$ADB" -d exec-out 'ls -laR /vendor/lib64/camera /vendor/lib/camera /vendor/etc/camera 2>&1' > "$dst/listing.txt"
		timeout 300 "$ADB" -d exec-out 'cd /vendor && find lib64/camera lib/camera -name "*sensormodule*" -o -name "*sensor*.bin" -o -name "*eeprom*" -o -name "*actuator*" -o -name "*flash*.bin" -o -name "*ois*" 2>/dev/null | xargs tar cf -' > "$dst/sensormodules.tar"
		timeout 120 "$ADB" -d exec-out 'cd /vendor/etc && tar cf - camera' > "$dst/etc-camera.tar"
		timeout 60 "$ADB" -d exec-out 'cd /proc/device-tree && find . -type d \( -name "qcom,cam-sensor@*" -o -name "qcom,actuator@*" -o -name "qcom,ois@*" -o -name "qcom,eeprom@*" -o -name "qcom,camera-flash@*" \) 2>/dev/null | xargs tar cf -' > "$dst/dt-camera-nodes.tar"
		ls -la "$dst"; tar tf "$dst/sensormodules.tar" | head -40; tar tf "$dst/dt-camera-nodes.tar" | grep -c . ; wc -l "$dst/listing.txt";;
	twrp-pull-qol)
		# everything the QoL workstreams still need, read only, in one TWRP session -> recon/fw-qol
		local dst=$P/ios-redfin-tree/ios-redfin/recon/fw-qol
		mkdir -p "$dst"
		timeout 30 "$ADB" -d shell 'mount | grep -q " /vendor " || mount -o ro /vendor'
		timeout 30 "$ADB" -d shell 'mkdir -p /mnt/vendor/persist; mount | grep -q " /mnt/vendor/persist " || mount -o ro /dev/block/by-name/persist /mnt/vendor/persist' ; timeout 10 "$ADB" -d shell 'mount | grep -E " /vendor | /mnt/vendor/persist "'
		timeout 120 "$ADB" -d exec-out 'cd /vendor/firmware && ls crbtfw* crnv* *cs35l41* *rt5514* *.wmfw 2>/dev/null | xargs tar cf -' > "$dst/bt-amp-fw.tar"
		timeout 120 "$ADB" -d exec-out 'cd /vendor/etc && tar cf - bluetooth audio_platform_info*.xml mixer_paths*.xml 2>/dev/null' > "$dst/bt-audio-etc.tar"
		timeout 180 "$ADB" -d exec-out 'cd /mnt/vendor/persist && tar cf - --exclude="*.bak" . 2>/dev/null' > "$dst/persist.tar"
		timeout 180 "$ADB" -d exec-out 'cd /vendor/lib64/camera && ls com.qti.tuned* 2>/dev/null | xargs tar cf -' > "$dst/camera-tuned.tar"
		timeout 60 "$ADB" -d exec-out 'cd /proc/device-tree && tar cf - soc/bt_wcn3990 soc/qcom,qup_uart@894000 2>/dev/null' > "$dst/dt-bt.tar"
		timeout 60 "$ADB" -d shell 'ls -la /vendor/firmware | grep -i -E "bt|cr|cs35|rt55|wmfw"; ls -la /mnt/vendor/persist; ls /vendor/etc/bluetooth' > "$dst/listing.txt" 2>&1
		ls -la "$dst"; for t in "$dst"/*.tar; do echo "== $t"; tar tvf "$t" | head -30; done; cat "$dst/listing.txt";;
	twrp-pull-log)
		local f=$P/logs/sweetlog-$(date +%Y%m%d-%H%M%S).bin
		timeout 120 "$ADB" -d exec-out 'b=$(readlink -f /dev/block/by-name/userdata); n=$(( $(blockdev --getsize64 $b) / 4096 )); dd if=$b bs=4096 skip=$((n - 2048)) count=2048 2>/dev/null' > "$f"
		ls -la "$f"; head -c 8 "$f"; echo;;
	git-pull) (cd "$REPO" && timeout 120 git pull --ff-only);;
	reload) echo "reloading"; RELOAD=1;;
	ssh-key)
		mkdir -p ~/.ssh "$P/agent/stage"; chmod 700 ~/.ssh
		[ -f ~/.ssh/redfin-claude ] || ssh-keygen -q -t ed25519 -N '' -C redfin-claude -f ~/.ssh/redfin-claude
		cp ~/.ssh/redfin-claude.pub "$P/agent/stage/authorized_keys"; cat ~/.ssh/redfin-claude.pub;;
	phone)
		timeout 300 ssh -i ~/.ssh/redfin-claude -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			-o ConnectTimeout=10 -o LogLevel=ERROR root@192.168.7.2 "$rest";;
	build-env) timeout 120 bash "$LB" env;;
	build-diag) timeout 170 bash "$LB" diag;;	# runs localbuild/diag.sh: one-off checks while porting a build
	build-apt)
		sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update -q 2>&1 | tail -2
		local have=() p; for p in $BUILD_APT; do
			if apt-cache show "$p" >/dev/null 2>&1; then have+=("$p"); else echo "(no package $p here)"; fi
		done
		timeout 1500 sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${have[@]}" 2>&1 | tail -8;;
	build-setup)
		[[ $rest =~ ^[a-z0-9-]+$ ]] || { echo "bad step"; return 1; }
		lb_bg setup "$rest";;
	build)
		read -r tgt ref <<<"$rest"
		[[ $tgt =~ ^(shim|userland|metal2|xnu)$ ]] || { echo "TARGET: shim userland metal2 xnu"; return 1; }
		[[ ${ref:-x} =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "bad ref"; return 1; }
		lb_bg build "$tgt" ${ref:-redfin-qol};;
	build-jobs) pgrep -af "localbuild/lb.sh" || echo "no local builds running";;
	build-kill)	# lb.sh runs under setsid: its pid is the process group of the whole build
		local k=0; for pid in $(pgrep -f "localbuild/lb.sh"); do kill -TERM -- "-$pid" 2>/dev/null && k=1; done
		[ $k = 1 ] && echo killed || echo "nothing running";;
	*) echo "unknown action: $act"; return 1;;
	esac
}

echo "phone-agent: watching $IN"
while true; do
	for r in "$IN"/*.req; do
		[ -e "$r" ] || continue
		n=$(basename "$r" .req)
		line=$(head -1 "$r" | tr -d '\r')
		rm -f "$r"
		echo "$(date +%T) $n: $line"
		{
			echo "\$ $line"
			run "$line" 2>&1
			echo "== exit $? at $(date +%T)"
		} > "$OUT/$n.tmp"
		mv "$OUT/$n.tmp" "$OUT/$n.out"
		tail -1 "$OUT/$n.out"
		if [ "${RELOAD:-0}" = 1 ]; then
			kill $KEEP $AUTO 2>/dev/null
			exec bash "$P/tools-claude/phone-agent.sh"
		fi
	done
	sleep 1
done
