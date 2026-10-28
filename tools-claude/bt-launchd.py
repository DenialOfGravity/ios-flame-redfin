#!/usr/bin/env python3
"""Bluetooth jobs in the iOS root's launchd.plist (redfin, kernel 1010 + 1015, phone/bt btd + bluetool).

  bt-launchd.py LAUNCHD.plist [--transport] [--bluetool [PATH]] [--btd-job [PATH]] [--revert] [--show]

LAUNCHD.plist is /System/Library/xpc/launchd.plist (of the mounted image, or a copy pulled from the phone with the
agent's `files get`, edited here, then put back). Binary plist in, binary plist out. Before the first change a copy
is written beside it as launchd.plist.before-bt (never overwritten: it stays the original); --revert puts it back.

  --transport      com.apple.bluetoothd gets EnvironmentVariables
                   BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000: the plain kernel control (1015)
                   instead of its default Skywalk control com.apple.uart.sk.bluetooth, which we cannot provide
                   (ios-asteroids docs/BT_IOS_TRANSPORT.md 1.3/2.1).
  --bluetool PATH  com.apple.BlueTool runs PATH -R (default /var/local/bin/bluetool, phone/bt/bluetool.c) instead
                   of /usr/sbin/BlueTool, whose Broadcom-only scripts fail on the WCN3998 (NO_FW_FOUND, result 13).
                   The stock binary is not touched.
  --btd-job PATH   adds org.iosonpixel.btd: PATH --bridge at boot as root (default /var/local/bin/btd-bridge, the
                   btd that runs on the phone), log /var/local/btd.log, restarted if it exits. Without it btd is
                   started by hand over SSH as before.
  --show           print the three jobs as they are and change nothing.
"""
import os, plistlib, shutil, sys

SUFFIX = '.before-bt'
TRANSPORT = 'H4BC:POSIX:com.apple.uart.bluetooth,3000000'
BTD_LABEL = 'org.iosonpixel.btd'


def load(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def save(path, data):
    with open(path, 'wb') as f:  # in place: keeps owner and mode
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)


def jobs_of(plist):
    for sect, jobs in plist.items():
        if isinstance(jobs, dict):
            for k, v in jobs.items():
                if isinstance(v, dict) and 'Label' in v:
                    yield sect, k, v


def job(plist, label):
    hits = [(s, k, j) for s, k, j in jobs_of(plist) if j.get('Label') == label]
    if not hits:
        raise SystemExit(f'no {label} job in the plist')
    return hits[0]


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        print(__doc__)
        return 0
    path, args = argv[1], argv[2:]
    backup = path + SUFFIX
    if '--revert' in args:
        if not os.path.exists(backup):
            raise SystemExit(f'no {backup}: nothing to revert')
        with open(backup, 'rb') as src, open(path, 'wb') as dst:
            dst.write(src.read())
        print(f'restored {path} from {backup}')
        return 0
    plist = load(path)
    if '--show' in args:
        for label in ('com.apple.bluetoothd', 'com.apple.BlueTool', BTD_LABEL):
            hits = [(s, k, j) for s, k, j in jobs_of(plist) if j.get('Label') == label]
            print(label, '->', hits[0][1] if hits else '(none)')
            for s, k, j in hits:
                for key in ('Program', 'ProgramArguments', 'EnvironmentVariables', 'UserName', 'RunAtLoad', 'KeepAlive'):
                    if key in j:
                        print('   ', key, '=', j[key])
        return 0

    def value(flag, default):
        i = args.index(flag)
        return args[i + 1] if i + 1 < len(args) and not args[i + 1].startswith('--') else default

    changed = []
    if '--transport' in args:
        _, _, j = job(plist, 'com.apple.bluetoothd')
        env = j.setdefault('EnvironmentVariables', {})
        env['BT_HCI_TRANSPORT'] = TRANSPORT
        changed.append(f'bluetoothd BT_HCI_TRANSPORT={TRANSPORT}')
    if '--bluetool' in args:
        prog = value('--bluetool', '/var/local/bin/bluetool')
        _, _, j = job(plist, 'com.apple.BlueTool')
        j['ProgramArguments'] = [prog, '-R']
        if 'Program' in j:
            j['Program'] = prog
        changed.append(f'BlueTool job runs {prog} -R')
    if '--btd-job' in args:
        prog = value('--btd-job', '/var/local/bin/btd-bridge')
        sect, _, ref = job(plist, 'com.apple.bluetoothd')  # same section as the system daemons
        plist[sect][f'/System/Library/LaunchDaemons/{BTD_LABEL}.plist'] = {
            'Label': BTD_LABEL,
            'ProgramArguments': [prog, '--bridge'],
            'RunAtLoad': True,
            'KeepAlive': {'SuccessfulExit': False},
            'ThrottleInterval': 10,
            'UserName': 'root',
            'StandardOutPath': '/var/local/btd.log',
            'StandardErrorPath': '/var/local/btd.log',
        }
        changed.append(f'{BTD_LABEL}: {prog} --bridge at boot')
    if not changed:
        raise SystemExit('nothing asked (--transport, --bluetool, --btd-job, --revert, --show)')
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f'original kept as {backup}')
    save(path, plist)
    for c in changed:
        print('set:', c)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
