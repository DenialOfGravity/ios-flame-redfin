# Windows version of tools/redfin-recon.sh: collect the Pixel 5 (redfin) facts the port
# needs. Read-only on the phone (vendor and modem are mounted read-only in TWRP).
#
#   powershell -ExecutionPolicy Bypass -File tools\redfin-recon.ps1 android   # stock Android, USB debugging on
#   powershell -ExecutionPolicy Bypass -File tools\redfin-recon.ps1 twrp      # in TWRP (adb root)
#
# Output: recon\ (keep it out of git: the device tree and getprop hold the serial number).
param([Parameter(Mandatory = $true)][ValidateSet("android", "twrp")][string]$Mode)
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..")
$O = "recon"; New-Item -ItemType Directory -Force -Path $O, "$O\fw" | Out-Null

function Adb-Sh([string]$cmd) { (& adb shell $cmd 2>&1 | Out-String).Replace("`r", "") }
function Save([string]$name, [string]$cmd) { Adb-Sh $cmd | Out-File (Join-Path $O $name) -Encoding ascii }

if ($Mode -eq "android") {
	& adb wait-for-device
	Save "getprop.txt" "getprop"
	Save "cmdline-android.txt" "cat /proc/cmdline"
	foreach ($k in "ro.product.device", "ro.build.fingerprint", "ro.bootloader", "ro.build.version.security_patch",
		"ro.boot.flash.locked", "ro.boot.verifiedbootstate", "ro.boot.slot_suffix", "ro.boot.hardware.revision") {
		"{0,-34} {1}" -f $k, (Adb-Sh "getprop $k").Trim()
	} | Tee-Object (Join-Path $O "summary-android.txt")
	exit 0
}

& adb wait-for-recovery
if ((Adb-Sh "id") -notmatch "uid=0") { Write-Error "adb is not root: boot TWRP first"; exit 1 }

# Live device tree as ABL handed it over (vendor_boot DTB + dtbo overlay + ABL fixups)
& adb pull /sys/firmware/fdt "$O\live.dtb" | Out-Null
Save "iomem.txt" "cat /proc/iomem"
Save "cmdline-twrp.txt" "cat /proc/cmdline"
Save "by-name.txt" "ls -l /dev/block/by-name/"
# (no double quotes inside adb shell commands: Windows PowerShell 5 mangles them)
Save "partitions.txt" 'for d in /sys/block/sd*/sd*; do echo ${d##*/} start=$(cat $d/start) size=$(cat $d/size) $(grep PARTNAME $d/uevent); done; for d in /sys/block/sd?; do echo ${d##*/} lbs=$(cat $d/queue/logical_block_size); done'
Save "memory-reg.txt" 'for f in /proc/device-tree/memory*/reg; do echo $f; od -An -tx4 -v $f; done'
Save "reserved-memory.txt" 'ls /proc/device-tree/reserved-memory/'
Save "model.txt" 'cat /proc/device-tree/model; echo; od -An -tx4 /proc/device-tree/qcom,msm-id; od -An -tx4 /proc/device-tree/qcom,board-id'
Save "dmesg-twrp.txt" "dmesg"

# Firmware: GPU from vendor, Wi-Fi/modem from the modem partition. Both mounted read-only.
$slot = (Adb-Sh "getprop ro.boot.slot_suffix").Trim()
Adb-Sh "mkdir -p /tmp/rv /tmp/rm; mount -o ro /dev/block/mapper/vendor$slot /tmp/rv 2>&1 || mount -o ro /vendor 2>&1; mount -t vfat -o ro /dev/block/by-name/modem$slot /tmp/rm 2>&1" | Out-File "$O\mounts.txt" -Encoding ascii
Save "vendor-firmware.txt" "ls -l /tmp/rv/firmware /vendor/firmware 2>/dev/null"
Save "modem-firmware.txt" "ls -lR /tmp/rm/image 2>/dev/null | head -400"
foreach ($f in (Adb-Sh "cd /tmp/rv/firmware 2>/dev/null || cd /vendor/firmware; ls a6*_gmu.bin a6*_sqe.fw a620_zap.* 2>/dev/null").Split("`n")) {
	$f = $f.Trim(); if ($f) { & adb pull "/tmp/rv/firmware/$f" "$O\fw\$f" 2>$null | Out-Null; if (-not (Test-Path "$O\fw\$f")) { & adb pull "/vendor/firmware/$f" "$O\fw\$f" | Out-Null } }
}
foreach ($f in (Adb-Sh "cd /tmp/rm/image && ls wlanmdsp.mbn modemuw.jsn modemr.jsn modem.mdt modem.b* bdwlan* 2>/dev/null").Split("`n")) {
	$f = $f.Trim(); if ($f) { & adb pull "/tmp/rm/image/$f" "$O\fw\$f" | Out-Null }
}
Adb-Sh "umount /tmp/rm; umount /tmp/rv" | Out-Null

Get-Content "$O\partitions.txt" | Select-String "userdata"
Get-Content "$O\memory-reg.txt"
Write-Host "GPU/Wi-Fi firmware pulled to $O\fw\:"; Get-ChildItem "$O\fw" | Format-Table Name, Length -AutoSize
Write-Host "Done. Leave recon\ in the project folder (Claude reads it from there)."
