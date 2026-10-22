#!/usr/bin/env python3
"""mtl-templates.py: SweetMetal pipeline templates for every pipeline a SweetMetal log shows.
  tools/mtl-templates.py LOG... [--only HASH] [--force]
For each pipeline key (tools/mtlkeys.py): specialise both AIR functions (airspec.py), translate them to GLSL
(air2glsl.py), capture one draw on turnip in the Lima VM (work/mesa/draw/capture.sh) and export the template
(rdtemplate.py) to phone/metal/pipelines/<sha1(key)[:12]>.json, with air2glsl's resource map under "res".
Work files in work/mtl/t/<hash>/. Pipelines that cannot be translated are listed with the reason.
"""
import hashlib, json, os, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import air2glsl, mtlkeys, rdtemplate

LIB = os.path.join(ROOT, 'research/gpu/QuartzCore.metallib')
OUT = os.path.join(ROOT, 'phone/metal/pipelines')
WORK = os.path.join(ROOT, 'work/mtl/t')
SPEC = os.path.join(ROOT, 'work/mtl/spec')

# Metal -> Vulkan formats
VTX = {25: 83, 26: 90, 27: 97, 28: 100, 29: 103, 30: 106, 31: 109}
PIX = {80: 44, 70: 37, 10: 9, 115: 97, 43: 8, 40: 4}

LIBS = os.path.join(ROOT, 'work/mtl/libs')

def phone_lib(path):
    """A metallib from the phone (cached in work/mtl/libs); QuartzCore's is in research/gpu."""
    if not path or path.endswith('QuartzCore.framework/default.metallib'):
        return LIB
    local = os.path.join(LIBS, path.strip('/').replace('/', '__'))
    if not os.path.exists(local):
        os.makedirs(LIBS, exist_ok=True)
        subprocess.run(['python3', os.path.join(ROOT, 'tools/flame-files.py'), 'get', path, local], capture_output=True)
    return local if os.path.exists(local) else None

_fns = {}
def lib_functions(lib):
    if lib not in _fns:
        out = subprocess.run(['python3', os.path.join(ROOT, 'tools/metallib.py'), lib], capture_output=True, text=True).stdout
        _fns[lib] = set(w for line in out.split('\n') for w in line.split())
    return _fns[lib]

def specialise(fn, fc, lib=LIB):
    key = [fn, fc] if lib == LIB else [fn, fc, os.path.basename(lib)]
    h = hashlib.sha1(json.dumps(key, sort_keys=True).encode()).hexdigest()[:10]
    out = os.path.join(SPEC, '%s-%s.ll' % (fn, h))
    if not os.path.exists(out):
        os.makedirs(SPEC, exist_ok=True)
        subprocess.run(['python3', os.path.join(ROOT, 'tools/airspec.py'), lib, fn, out] +
                       ['%s=%s' % kv for kv in fc.items()], check=True, capture_output=True)
    return out

def vertex_layout(vd):
    """'a0=fmt31@0/b1 a1=fmt29@16/b1 ... b1 stride 48 step 1' -> '48;0,109,0;1,103,16;...' (buffer 1 only)"""
    import re
    stride = re.search(r'b1 stride (\d+)', vd)
    attrs = re.findall(r'a(\d+)=fmt(\d+)@(\d+)/b1', vd)
    if not stride:
        return None
    for _, f, _ in attrs:
        if int(f) not in VTX:
            raise air2glsl.Unsupported('vertex format %s' % f)
    return stride.group(1) + ''.join(';%s,%d,%s' % (a, VTX[int(f)], o) for a, f, o in attrs)

def build(k, force=False, topo=3):
    """topo: VkPrimitiveTopology of the capture (3 triangles; 1 lines -> <hash>-l.json, for line draws)"""
    h = hashlib.sha1(k['raw'].encode()).hexdigest()[:12]
    if topo != 3:
        h += {1: '-l', 0: '-p'}[topo]
    dst = os.path.join(OUT, h + '.json')
    if os.path.exists(dst) and not force:
        return h, 'exists'
    layout = vertex_layout(k['vd']) if k['vd'] else ''
    if layout is None:
        return h, 'vertex layout %r' % k['vd']
    dest = int(k['ffc'].get('dest_index', '0'))
    if dest == 0 and k.get('wm', 15) == 0 and (k['att'].get('1', [0, 0]) + [15])[2] != 0 and '1' in k['att']:
        dest = 1        # attachment 0 masked off: it draws attachment 1 (CA's attachment_clear clears it)
    if dest > 1:
        return h, 'dest_index %d' % dest
    fmt = k['fmt'] if dest == 0 else k['att'][str(dest)][0]
    if fmt not in PIX:
        return h, 'target format %d' % fmt
    blend = k['blend'] if dest == 0 else k['att'].get(str(dest), [0, 0])[1]
    bf = k.get('bf') if dest == 0 else (k['att'].get(str(dest), [0, 0, 15, None]) + [None])[3]
    if blend and bf:
        # Metal -> Vulkan blend factors (operations are numbered alike); vkdraw takes "s,d,op,sa,da,aop"
        vf = {0: 0, 1: 1, 2: 2, 3: 3, 4: 6, 5: 7, 6: 4, 7: 5, 8: 8, 9: 9, 10: 14, 11: 10, 12: 11, 13: 12, 14: 13,
              15: 15, 16: 16, 17: 17, 18: 18}
        blend = ','.join(str(vf[x]) if i % 3 != 2 else str(x) for i, x in enumerate(bf))
    wmask = k.get('wm', 15) if dest == 0 else (k['att'].get(str(dest), [0, 0, 15]) + [15])[2]
    if wmask == 0:
        return h, 'writes nothing (write mask 0)'
    # Metal MTLColorWriteMask: alpha 1, blue 2, green 4, red 8; Vulkan: R 1, G 2, B 4, A 8
    vkmask = (8 if wmask & 1 else 0) | (4 if wmask & 2 else 0) | (2 if wmask & 4 else 0) | (1 if wmask & 8 else 0)
    v, f = specialise(k['vs'], k['vfc'], k['_vlib']), specialise(k['fs'], k['ffc'], k['_flib'])
    vt, ft, res = air2glsl.translate_pair(open(v).read(), open(f).read(), dest)
    d = os.path.join(WORK, h)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, 'vs.vert'), 'w').write(vt)
    open(os.path.join(d, 'fs.frag'), 'w').write(ft)
    rel = os.path.relpath(d, ROOT)
    r = subprocess.run(['limactl', 'shell', '--workdir', ROOT, 'iosroot', 'sh', 'work/mesa/draw/capture.sh',
                        rel + '/vs.vert', rel + '/fs.frag', rel + '/cap', str(blend), layout, str(PIX[fmt]), str(topo), str(vkmask)],
                       capture_output=True, text=True)
    rds = [x for x in os.listdir(os.path.join(d, 'cap')) if x.endswith('.rd')] if os.path.isdir(os.path.join(d, 'cap')) else []
    if r.returncode or not rds:
        open(os.path.join(d, 'capture.log'), 'w').write(r.stdout + r.stderr)
        return h, 'capture failed (%s/capture.log)' % rel
    t = rdtemplate.export(os.path.join(d, 'cap', rds[0]), dst)
    t['res'] = res
    t['key'] = k['raw']
    json.dump(t, open(dst, 'w'))
    return h, 'ok'

if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    if only:
        args.remove(only)
    lines = []
    for p in args:
        lines += open(p, errors='replace').read().split('\n')
    for k in mtlkeys.parse(lines):
        h = hashlib.sha1(k['raw'].encode()).hexdigest()[:12]
        if only and h != only:
            continue
        k['_vlib'], k['_flib'] = phone_lib(k.get('vlib')), phone_lib(k.get('flib'))
        if not k['_vlib'] or not k['_flib']:
            print('%s          %s + %s  -- metallib not found (%s | %s)' % (h, k['vs'], k['fs'], k.get('vlib'), k.get('flib')))
            continue
        if k['vs'] not in lib_functions(k['_vlib']) or k['fs'] not in lib_functions(k['_flib']):
            continue
        try:
            h, st = build(k, '--force' in sys.argv)
            if st in ('ok', 'exists') and k['vd'] and 'vertex_layout=1' in k['raw']:
                build(k, '--force' in sys.argv, topo=1)	# CA draws edge antialiasing lines with these
        except air2glsl.Unsupported as e:
            st = 'unsupported: %s' % e
        print('%s %-8s %s + %s' % (h, st if st in ('ok', 'exists') else '', k['vs'], k['fs']) +
              ('' if st in ('ok', 'exists') else '  -- ' + st), flush=True)
