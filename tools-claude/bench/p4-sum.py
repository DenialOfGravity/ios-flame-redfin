import json,sys,glob,os
d=sorted(glob.glob('logs/traces/%s-*/summary.json'%sys.argv[1]),key=os.path.getmtime)[-1]
s=json.load(open(d)); print(d)
for k in ('frames','swipe_fps','interval_vsyncs_swipe','late_intervals_swipe','interval_ms','onscreen_interval_vsyncs','onscreen_interval_ms','gpu_ms_swipe','chain','warning'):
  print(k, json.dumps(s.get(k))[:300])
