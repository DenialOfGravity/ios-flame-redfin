#!/usr/bin/env python3
"""Give iOS a Wi-Fi network service (en0, DHCP) on the Pixel 4a.

iOS's preferences.plist on this install had no network set: it was written before en0 existed, so configd never
made its default configuration and IPConfiguration never ran DHCP on en0 (joined, but no IP). This adds the
service + set configd would have made. Usage: tools/sunfish-netprefs.py (phone reachable; restarts configd).
"""
import plistlib, subprocess, sys, tempfile, os

PREFS = '/var/preferences/SystemConfiguration/preferences.plist'
SVC = '5EE7C0DE-5EE7-4000-8000-00000000E000'
SET = '5EE7C0DE-5EE7-4000-8000-00000000A000'
here = os.path.dirname(os.path.abspath(__file__))
files = [sys.executable, '-I', os.path.join(here, 'flame-files.py')]

with tempfile.TemporaryDirectory() as d:
    cur, new = os.path.join(d, 'cur.plist'), os.path.join(d, 'new.plist')
    subprocess.run(files + ['get', PREFS, cur], check=True, stdout=subprocess.DEVNULL)
    p = plistlib.load(open(cur, 'rb'))
    p.setdefault('NetworkServices', {})[SVC] = {
        'DNS': {}, 'IPv4': {'ConfigMethod': 'DHCP'}, 'IPv6': {'ConfigMethod': 'Automatic'},
        'Proxies': {'ExceptionsList': ['*.local', '169.254/16'], 'FTPPassive': 1},
        'Interface': {'DeviceName': 'en0', 'Hardware': 'AirPort', 'Type': 'Ethernet', 'UserDefinedName': 'Wi-Fi'},
        'UserDefinedName': 'Wi-Fi'}
    p.setdefault('Sets', {})[SET] = {
        'Network': {'Global': {'IPv4': {'ServiceOrder': [SVC]}},
                    'Interface': {'en0': {'AirPort': {'JoinModeFallback': ['DoNothing'], 'PowerEnabled': True}}},
                    'Service': {SVC: {'__LINK__': '/NetworkServices/' + SVC}}},
        'UserDefinedName': 'Automatic'}
    p['CurrentSet'] = '/Sets/' + SET
    plistlib.dump(p, open(new, 'wb'), fmt=plistlib.FMT_BINARY)
    subprocess.run(files + ['put', new, PREFS, '644'], check=True)
subprocess.run([os.path.join(here, 'sunfish-ssh'), 'for p in $(psx configd | cut -c1-6); do kill $p; done'], check=False)
print('Wi-Fi service added; configd restarted')
