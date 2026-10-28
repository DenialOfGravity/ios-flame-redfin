#!/usr/bin/env python3
"""swtr-reduce.py IN.swtr OUT.swtr [PROC ...]: keep only what sweet-trace.py needs for the frame chain of the given
processes (default backboardd SpringBoard Preferences): all 0994 events, IPC kmsg info, the MACH_IPC_MSG_SEND / RECV
events (msgh_id, kmsg) of their threads (for sweet-trace.py --ipc / --chain), thread names, interrupts, wakes of their
threads and context switches in/out of their threads. Same file format, events in time order."""
import struct
import sys
import numpy as np

HDR = struct.Struct('<8sIIIIQQQIIIIIIiIQ128s')
THR = struct.Struct('<QiI32s64s')
KD = np.dtype([('ts', '<u8'), ('a1', '<u8'), ('a2', '<u8'), ('a3', '<u8'), ('a4', '<u8'), ('tid', '<u8'),
               ('dbg', '<u4'), ('cpu', '<u4'), ('pad', '<u8')])
assert KD.itemsize == 64


def code(cls, sub, c):
    return (cls << 24) | (sub << 16) | (c << 2)


SCHED = code(1, 0x40, 0x00)
HANDOFF = code(1, 0x40, 0x02)
MKRUN = code(1, 0x40, 0x06)
INTR = code(1, 0x05, 0)
KMSG = code(1, 0x20, 0x0a)
IPC_MSG = [code(1, 0x20, 0x03), code(1, 0x20, 0x04), code(1, 0x20, 0x05)]   # MSG_SEND, MSG_RECV, MSG_RECV_NV
SW_BASE = (6 << 24) | (0xF5 << 16)

src, dst = sys.argv[1], sys.argv[2]
procs = set(sys.argv[3:] or ['backboardd', 'SpringBoard', 'Preferences'])
data = open(src, 'rb').read()
h = list(HDR.unpack_from(data, 0))
hsize, n_ev, n_thr = h[2], h[7], h[8]
ev = np.frombuffer(data, dtype=KD, count=n_ev, offset=hsize)
toff = hsize + n_ev * KD.itemsize
thr_bytes = data[toff:toff + n_thr * THR.size]
focus = set()
for tid, pid, flags, comm, name in THR.iter_unpack(thr_bytes):
    if comm.split(b'\0', 1)[0].decode('utf-8', 'replace') in procs:
        focus.add(tid)
order = np.argsort(ev['ts'], kind='stable')
ev = ev[order]
cid = ev['dbg'] & np.uint32(0xfffffffc)
keep = ((ev['dbg'] & np.uint32(0xffff0000)) == SW_BASE) | (cid == KMSG) | ((ev['dbg'] >> np.uint32(24)) == 7) | \
       (cid == INTR)
fa = np.array(sorted(focus), dtype=np.uint64)
keep |= (cid == MKRUN) & np.isin(ev['a1'], fa)
keep |= np.isin(cid, np.array(IPC_MSG, dtype=np.uint32)) & np.isin(ev['tid'], fa)
si = np.nonzero((cid == SCHED) | (cid == HANDOFF))[0]
cpu_cur = {}
s_cpu = ev['cpu'][si].tolist()
s_new = ev['a2'][si].tolist()
s_tid = ev['tid'][si].tolist()
km = np.zeros(len(si), dtype=bool)
for k in range(len(si)):
    c = s_cpu[k]
    old = cpu_cur.get(c, s_tid[k])
    new = s_new[k]
    if old != new and (old in focus or new in focus):
        km[k] = True
    cpu_cur[c] = new
keep[si[km]] = True
out = ev[keep]
h[7] = len(out)
with open(dst, 'wb') as f:
    f.write(HDR.pack(*h))
    f.write(data[HDR.size:hsize])
    f.write(out.tobytes())
    f.write(thr_bytes)
print(f'{src}: {n_ev} -> {len(out)} events, {len(focus)} focus threads')
