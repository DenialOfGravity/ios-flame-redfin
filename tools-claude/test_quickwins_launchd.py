#!/usr/bin/env python3
"""python3 -I tools-claude/test_quickwins_launchd.py  (synthetic root in a temp dir)"""
import os, plistlib, subprocess, sys, tempfile, unittest

S = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'quickwins-launchd.py')


def run(*a):
    r = subprocess.run([sys.executable, '-I', S, *a], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.d, 'System/Library/xpc'))
        self.lp = os.path.join(self.d, 'System/Library/xpc/launchd.plist')
        self.pp = os.path.join(self.d, 'private/var/mobile/Library/Preferences/com.apple.springboard.plist')
        self.orig = {'LaunchDaemons': {
            '/System/Library/LaunchDaemons/com.apple.backboardd.plist': {'Label': 'com.apple.backboardd', 'EnvironmentVariables': {'A': 'b'}},
            '/System/Library/LaunchDaemons/com.apple.fairplayd.H2.plist': {'Label': 'com.apple.fairplayd.H2'},
            '/System/Library/LaunchDaemons/com.apple.locationd.plist': {'Label': 'com.apple.locationd'}}}
        with open(self.lp, 'wb') as f:
            plistlib.dump(self.orig, f, fmt=plistlib.FMT_BINARY)

    def jobs(self):
        return plistlib.load(open(self.lp, 'rb'))['LaunchDaemons']

    def test_ca_timer_only(self):
        rc, out = run(self.lp, '--ca-timer')
        self.assertEqual(rc, 0, out)
        j = self.jobs()
        self.assertEqual(j['/System/Library/LaunchDaemons/com.apple.backboardd.plist']['EnvironmentVariables'],
                         {'A': 'b', 'CA_FORCE_TIMER': '1'})
        self.assertIn('/System/Library/LaunchDaemons/com.apple.fairplayd.H2.plist', j)  # untouched
        self.assertTrue(open(self.lp, 'rb').read().startswith(b'bplist00'))
        self.assertEqual(plistlib.load(open(self.lp + '.before-quickwins', 'rb')), self.orig)
        self.assertIn('already set', run(self.lp, '--ca-timer')[1])

    def test_fairplayd_and_revert(self):
        run(self.lp, '--ca-timer')
        rc, out = run(self.lp, '--no-fairplayd')
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.jobs()), 2)
        self.assertEqual(plistlib.load(open(self.lp + '.before-quickwins', 'rb')), self.orig)  # backup kept original
        self.assertIn('not present', run(self.lp, '--no-fairplayd')[1])
        run(self.lp, '--revert')
        self.assertEqual(plistlib.load(open(self.lp, 'rb')), self.orig)

    def test_prefs_new_and_existing(self):
        rc, out = run(self.lp, '--bk-nowatchdogs')
        self.assertEqual(rc, 0, out)
        self.assertIs(plistlib.load(open(self.pp, 'rb'))['BKNoWatchdogs'], True)
        run(self.lp, '--revert')
        self.assertFalse(os.path.exists(self.pp))
        plistlib.dump({'X': 1}, open(self.pp, 'wb'), fmt=plistlib.FMT_BINARY)
        run(self.lp, '--bk-nowatchdogs')
        self.assertEqual(plistlib.load(open(self.pp, 'rb')), {'X': 1, 'BKNoWatchdogs': True})
        run(self.lp, '--revert')
        self.assertEqual(plistlib.load(open(self.pp, 'rb')), {'X': 1})
        self.assertEqual(plistlib.load(open(self.lp, 'rb')), self.orig)  # launchd untouched by prefs-only

    def test_usage_and_missing_job(self):
        self.assertNotEqual(run(self.lp)[0], 0)
        self.assertNotEqual(run(self.lp, '--bogus')[0], 0)
        os.remove(self.lp)
        plistlib.dump({'LaunchDaemons': {}}, open(self.lp, 'wb'))
        self.assertNotEqual(run(self.lp, '--ca-timer')[0], 0)


if __name__ == '__main__':
    unittest.main()
