import re, sys
# SweetMetal dump: "v0..v3" lines and "prim" come before their "dump: HASH fn vp .. sc .. textures" line
x0, y0, x1, y1 = map(float, sys.argv[2:6])
verts = []
for line in open(sys.argv[1], errors='replace'):
    m = re.search(r'dump:   v\d (\S+) (\S+)', line)
    if m:
        verts.append((float(m.group(1)), float(m.group(2))))
        continue
    m = re.search(r'dump: ([0-9a-f]{12}) (\S+) (vp .*)$', line)
    if m:
        if verts:
            xs = [v[0] for v in verts]; ys = [v[1] for v in verts]
            if min(xs) < x1 and max(xs) > x0 and min(ys) < y1 and max(ys) > y0:
                print(m.group(1), m.group(2), 'verts x %.0f..%.0f y %.0f..%.0f' % (min(xs), max(xs), min(ys), max(ys)), m.group(3)[:150])
        verts = []
    if '== pass' in line:
        print('   ', line.strip()[line.find('== pass'):][:100])
