#!/usr/bin/env python3
"""Optional boot-time tweaks for the iOS root: launchd.plist jobs and one SpringBoard default.

  quickwins-launchd.py LAUNCHD.plist [--ca-timer] [--bk-nowatchdogs] [--no-fairplayd] [--revert]
                       [--springboard-prefs PATH]

LAUNCHD.plist is /System/Library/xpc/launchd.plist of the root (the mounted image: "$M/System/Library/xpc/...";
or on the phone). Binary plist in, binary plist out. Before the first change a copy is written beside it as
launchd.plist.before-quickwins (never overwritten, so it stays the original); --revert puts it back.

  --ca-timer         backboardd gets EnvironmentVariables CA_FORCE_TIMER=1. QuartzCore's CADeviceUseVBL() is true
                     only for that env var or a list of A7-A10 chip ids; ours is 0x8015, so Core Animation never
                     subscribed to the display's vsync (sunfish docs/workday.md "CA vsync", 7058eca: swaps ==
                     panel updates, no dropped swaps). Needs an IOMFB that delivers vsync notifications (type 5).
                     Not applied by default: check the kernel's vsync first (sunfish pacing result is not
                     proven on redfin).
  --bk-nowatchdogs   NOT a launchd key: a SpringBoard default, BKNoWatchdogs=true, written to
                     <root>/private/var/mobile/Library/Preferences/com.apple.springboard.plist (root = the part of
                     LAUNCHD.plist before System/Library/xpc/, or --springboard-prefs PATH), backup
                     <that file>.before-quickwins (or .absent if there was none). tools/sweet-root-tweaks.py
                     already sets it on a freshly built root; this is for an existing image.
  --no-fairplayd     removes the com.apple.fairplayd.H2 job. It exits right after a container lookup and launchd
                     relaunches it every 10 s; MIG requests to com.apple.fairplayd.versioned then queue forever,
                     and locationd's CLMescalSigner (FairPlay SAPInit) deadlocks its main thread, hanging every
                     app that makes a synchronous CoreLocation call (flame HANDOFF.md l.238). TRADE-OFF: without
                     the job nothing answers FairPlay requests at all, so DRM'd apps (App Store purchases,
                     Apple Music/TV downloads) cannot work. They did not work with the dead daemon either, but
                     this needs the user's approval before use.
"""
import os, plistlib, shutil, sys

SUFFIX = '.before-quickwins'
ABSENT = SUFFIX + '.absent'
LAUNCHD_TAIL = os.path.join('System', 'Library', 'xpc', 'launchd.plist')
PREFS_REL = os.path.join('private', 'var', 'mobile', 'Library', 'Preferences', 'com.apple.springboard.plist')


def load(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def save(path, data):
    with open(path, 'wb') as f:  # in place: keeps owner and mode
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)


def jobs_of(plist):
    """(section, key, job) of every launchd job dict."""
    for sect, jobs in plist.items():
        if isinstance(jobs, dict):
            for k, v in jobs.items():
                if isinstance(v, dict):
                    yield sect, k, v


def ca_timer(plist):
    hits = [j for _, _, j in jobs_of(plist) if j.get('Label') == 'com.apple.backboardd']
    if not hits:
        raise SystemExit('--ca-timer: no com.apple.backboardd job in the plist')
    msgs = []
    for j in hits:
        env = j.setdefault('EnvironmentVariables', {})
        if env.get('CA_FORCE_TIMER') == '1':
            msgs.append('backboardd: CA_FORCE_TIMER=1 already set')
        else:
            env['CA_FORCE_TIMER'] = '1'
            msgs.append('backboardd: CA_FORCE_TIMER=1 set')
    return msgs


def no_fairplayd(plist):
    drop = [(s, k) for s, k, j in jobs_of(plist)
            if j.get('Label') == 'com.apple.fairplayd.H2' or os.path.basename(k) == 'com.apple.fairplayd.H2.plist']
    for s, k in drop:
        del plist[s][k]
    return [f'removed {s}/{k}' for s, k in drop] or ['fairplayd.H2: not present (already removed)']


def backup(path, absent_ok=False):
    bak = path + SUFFIX
    if os.path.exists(bak) or os.path.exists(path + ABSENT):
        return
    if os.path.exists(path):
        shutil.copy2(path, bak)
        print('backup', bak)
    elif absent_ok:
        open(path + ABSENT, 'w').close()
        print('backup marker', path + ABSENT, '(file did not exist)')


def restore(path):
    bak = path + SUFFIX
    if os.path.exists(bak):
        shutil.copy2(bak, path)
        print('restored', path, 'from', bak)
    elif os.path.exists(path + ABSENT):
        if os.path.exists(path):
            os.remove(path)
        os.remove(path + ABSENT)
        print('removed', path, '(it did not exist before)')
    else:
        print('no backup for', path, '- nothing to revert')


def main(argv):
    flags = {a for a in argv if a.startswith('--')}
    args = [a for a in argv if not a.startswith('--')]
    prefs = None
    if '--springboard-prefs' in argv:
        i = argv.index('--springboard-prefs')
        prefs = argv[i + 1] if i + 1 < len(argv) else None
        args = [a for a in args if a != prefs]
        flags.discard('--springboard-prefs')
    known = {'--ca-timer', '--bk-nowatchdogs', '--no-fairplayd', '--revert'}
    if len(args) != 1 or flags - known or not flags or ('--revert' in flags and len(flags) > 1):
        sys.exit(__doc__)
    path = args[0]
    if not os.path.isfile(path) and '--revert' not in flags:
        sys.exit(f'{path}: not a file')
    if prefs is None and path.endswith(LAUNCHD_TAIL):
        prefs = os.path.join(path[:-len(LAUNCHD_TAIL)] or '/', PREFS_REL)

    if '--revert' in flags:
        restore(path)
        if prefs:
            restore(prefs)
        return

    launchd_flags = flags & {'--ca-timer', '--no-fairplayd'}
    if launchd_flags:
        plist = load(path)
        backup(path)
        msgs = []
        if '--ca-timer' in flags:
            msgs += ca_timer(plist)
        if '--no-fairplayd' in flags:
            msgs += no_fairplayd(plist)
        save(path, plist)
        for m in msgs:
            print(path + ':', m)
    if '--bk-nowatchdogs' in flags:
        if not prefs:
            sys.exit('--bk-nowatchdogs: cannot derive the preferences path; pass --springboard-prefs PATH')
        os.makedirs(os.path.dirname(prefs), exist_ok=True)
        backup(prefs, absent_ok=True)
        data = load(prefs) if os.path.exists(prefs) else {}
        was = data.get('BKNoWatchdogs')
        data['BKNoWatchdogs'] = True
        new = not os.path.exists(prefs)
        save(prefs, data)
        if new:
            os.chown(prefs, 501, 501) if os.geteuid() == 0 else None
            os.chmod(prefs, 0o600)
        print(prefs + ':', 'BKNoWatchdogs already true' if was is True else 'BKNoWatchdogs=true set')


if __name__ == '__main__':
    main(sys.argv[1:])
