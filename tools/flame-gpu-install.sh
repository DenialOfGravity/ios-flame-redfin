#!/bin/bash
# Install pmem + gpu (phone/gpu, built with phone/gpu/build.sh) and the Adreno firmware
# (research/gpu/fw, from the stock vendor image: never commit or publish it) into the
# running iOS through the file server. Then: tools/flame-ssh 'gpu up -p'.
set -euo pipefail
cd "$(dirname "$0")/.."
phone/gpu/build.sh >/dev/null
F="python3 tools/flame-files.py"
$F mkdir /var/local/gpu 755 >/dev/null
$F mkdir /var/local/gpu/fw 755 >/dev/null
for b in pmem gpu; do $F put phone/gpu/out/$b /var/local/bin/$b 755; done
for f in a640_gmu.bin a630_sqe.fw a640_zap.mdt a640_zap.b02; do
	$F put research/gpu/fw/$f /var/local/gpu/fw/$f 644
done
python3 tools/flame-cmd.py sync >/dev/null 2>&1 || true	# flush to UFS (a panic would lose the files)
