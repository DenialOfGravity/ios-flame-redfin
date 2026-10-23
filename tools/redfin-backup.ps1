# Back up every Pixel 5 (redfin) partition except userdata and super, from TWRP.
# Read-only on the phone: each partition is copied with dd into TWRP's RAM (/tmp),
# pulled with adb, hashed and deleted from /tmp. Nothing on the phone's storage is written.
#
#   powershell -ExecutionPolicy Bypass -File tools\redfin-backup.ps1 [-Out backup]
#
# The phone must be in TWRP (fastboot boot twrp-*-redfin.img) with adb working.
# persist, modemst1/2, fsg and fsc hold the IMEI and calibration: keep backup\ private and
# out of git. userdata (Android data) and super (system/vendor, restorable from the
# factory image) are skipped.
param([string]$Out = "backup")
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Adb-Sh([string]$cmd) { (& adb shell $cmd 2>&1 | Out-String).Replace("`r", "").Trim() }

& adb wait-for-recovery
if ((Adb-Sh "id") -notmatch "uid=0") { throw "adb is not root: boot TWRP first" }
$model = Adb-Sh "getprop ro.product.device"
Write-Host "device: $model"
if ($model -notmatch "redfin") { Write-Warning "this is not a redfin; stopping"; exit 1 }

$skip = @("userdata", "super")
# TWRP also lists whole disks (sda = all 128 GB of storage, sdb-sdf): never copy those.
$names = (Adb-Sh "ls /dev/block/by-name/").Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
# RAM free in TWRP, in bytes: parse /proc/meminfo here, not in the phone's shell
$memLine = (Adb-Sh "cat /proc/meminfo").Split("`n") | Where-Object { $_ -match '^MemAvailable:\s+(\d+)' } | Select-Object -First 1
$free = 0
if ($memLine -match '^MemAvailable:\s+(\d+)') { $free = [int64]$Matches[1] * 1024 }
Write-Host ("TWRP free RAM: {0:N0} bytes" -f $free)
if ($free -lt 512MB) { throw "could not read TWRP's free RAM (got $free); stopping" }
$log = Join-Path $Out "backup-log.txt"
"redfin backup $(Get-Date -Format s)" | Out-File $log -Encoding ascii

foreach ($n in $names) {
	if ($skip -contains $n -or $n -match '^sd[a-z]$') { Write-Host "skip  $n"; continue }
	$dev = Adb-Sh "readlink -f /dev/block/by-name/$n"
	$size = [int64](Adb-Sh "blockdev --getsize64 $dev")
	if ($size -gt ($free / 2)) { Write-Warning "skip  $n ($size bytes, too big for /tmp)"; "SKIPPED $n $size" | Add-Content $log; continue }
	$dst = Join-Path $Out "$n.img"
	if (Test-Path $dst) { Write-Host "have  $n"; continue }
	Write-Host ("copy  {0,-24} {1,12:N0} bytes" -f $n, $size)
	Adb-Sh "dd if=$dev of=/tmp/bk.img bs=1048576 2>/dev/null" | Out-Null
	$phoneSum = (Adb-Sh "sha256sum /tmp/bk.img").Split(" ")[0]
	& adb pull /tmp/bk.img $dst | Out-Null
	Adb-Sh "rm -f /tmp/bk.img" | Out-Null
	$pcSum = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
	if ($pcSum -ne $phoneSum) { Remove-Item $dst; throw "hash mismatch on $n" }
	"$pcSum  $n.img  $size" | Add-Content $log
}
Write-Host "done: $Out\ ($((Get-ChildItem $Out -Filter *.img).Count) partitions). Hashes in $log"
Write-Host "Copy backup\ somewhere off this PC too (USB stick / private cloud)."
