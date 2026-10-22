#!/bin/bash
# Faster Metal loop than a reboot: build SweetMetal.bundle, swap its binary on the running phone (put to a temp
# name, then mv over: the old one stays mapped in the dying backboardd), restart backboardd.
set -euo pipefail
cd "$(dirname "$0")/.."
phone/metal/build.sh >/dev/null
D=/System/Library/Extensions/SweetMetal.bundle
python3 tools/flame-files.py put phone/metal/out/SweetMetal.bundle/SweetMetal $D/SweetMetal.new 755 >/dev/null
python3 tools/flame-files.py put phone/metal/out/SweetMetal.bundle/_CodeSignature/CodeResources $D/_CodeSignature/CodeResources 644 >/dev/null
python3 tools/flame-files.py mkdir $D/pipelines 755 >/dev/null 2>&1 || true
# PUT does not truncate an existing file: write new names, then move them over
# only templates that differ from the phone's (md5)
remote=$(tools/flame-ssh "cd $D/pipelines && md5sum *.json 2>/dev/null" || true)
for f in phone/metal/out/SweetMetal.bundle/pipelines/*.json; do
	b=$(basename "$f")
	m=$(md5 -q "$f")
	printf '%s\n' "$remote" | grep -q "^$m  $b\$" && continue
	python3 tools/flame-files.py put "$f" "$D/pipelines/$b.new" 644 >/dev/null
done
tools/flame-ssh "for f in \$(ls $D/pipelines/*.new 2>/dev/null); do mv \"\$f\" \"\${f%.new}\"; done; mv $D/SweetMetal.new $D/SweetMetal && psx -k backboardd" | tail -1
