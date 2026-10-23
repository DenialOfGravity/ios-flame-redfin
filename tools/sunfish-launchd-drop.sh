#!/bin/bash
# Remove launchd jobs (by label) from the phone's job cache; first run keeps
# /System/Library/xpc/launchd.plist.pre-drop on the phone. Reboot to apply.
#   tools/sunfish-launchd-drop.sh LABEL...
set -euo pipefail
cd "$(dirname "$0")/.."
F() { python3 -I tools/flame-files.py "$@"; }
U=work/userland
F get /System/Library/xpc/launchd.plist $U/launchd.plist.cur >/dev/null
[ -f $U/launchd.plist.pre-drop ] || { cp $U/launchd.plist.cur $U/launchd.plist.pre-drop; F put $U/launchd.plist.pre-drop /System/Library/xpc/launchd.plist.pre-drop 644 >/dev/null; }
python3 -I - "$U/launchd.plist.cur" "$U/launchd.plist.new" "$@" <<'PY'
import plistlib, sys
src, dst, labels = sys.argv[1], sys.argv[2], set(sys.argv[3:])
p = plistlib.load(open(src, 'rb'))
for sect, jobs in p.items():
    if isinstance(jobs, dict):
        for k in [k for k, v in jobs.items() if isinstance(v, dict) and v.get('Label') in labels]:
            print('dropped', sect, jobs.pop(k)['Label'])
plistlib.dump(p, open(dst, 'wb'), fmt=plistlib.FMT_BINARY)
PY
F put $U/launchd.plist.new /System/Library/xpc/launchd.plist 644 >/dev/null
python3 -I tools/flame-cmd.py sync >/dev/null 2>&1 || true
echo "done; reboot to apply"
