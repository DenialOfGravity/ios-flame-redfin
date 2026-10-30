# g9-diff.py A B: per screen max/mean abs diff and pixels >2, full and without the status bar (top 150 rows)
import sys,numpy as np
from PIL import Image
P='/sessions/'  # unused
import os
base=os.path.expanduser('~/mnt/iOS_Pixel5/logs/bench/')
for s in ('settings','cc','home','safari','photos'):
    fa=base+f'p4-g9-{sys.argv[1]}-{s}.png'; fb=base+f'p4-g9-{sys.argv[2]}-{s}.png'
    if not (os.path.exists(fa) and os.path.exists(fb)): print(s,'missing');continue
    a=np.asarray(Image.open(fa).convert('RGB')).astype(int); b=np.asarray(Image.open(fb).convert('RGB')).astype(int)
    if a.shape!=b.shape: print(s,'shape',a.shape,b.shape);continue
    d=np.abs(a-b); m=d.max(axis=2); m2=m[150:]
    print(f"{s:8s} full max {d.max():3d} mean {d.mean():.3f} px>2 {(m>2).sum():7d} | no-statusbar max {m2.max():3d} px>2 {(m2>2).sum():7d} mean-signed {(a-b)[150:].mean():+.3f}")
