#!/usr/bin/env python3
"""pstack-sym.py PSTACK.txt: symbolicate phone/tools pstack output (shared-cache frames, via ipsw + a lookup cache)."""
import re, subprocess, sys
DSC = 'research/dsc/dyld_shared_cache_arm64'
text = open(sys.argv[1]).read()
slide = int(re.search(r'slide 0x([0-9a-f]+)', text).group(1), 16)
memo = {}
def sym(a):
    if a < 0x180000000 + slide:
        return '?'
    if a not in memo:
        r = subprocess.run(['ipsw', 'dyld', 'a2s', DSC, hex(a), '-s', hex(slide), '--cache', 'work/a2s.cache'],
                           capture_output=True, text=True)
        out = (r.stdout.strip() or r.stderr.strip()).split('\n')[-1]
        memo[a] = re.sub(r'^0x[0-9a-f]+: ', '', out)
    return memo[a]
for line in text.split('\n'):
    if line.strip().startswith('bt'):
        for x in line.split()[1:]:
            print('    %s %s' % (x, sym(int(x, 16))))
    else:
        print(line)
