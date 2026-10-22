#!/usr/bin/env python3
"""air2glsl.py: a specialised AIR vertex + fragment function pair (airspec.py output) -> Vulkan GLSL.
  air2glsl.py VS.ll FS.ll OUTDIR       -> OUTDIR/vs.vert, fs.frag, res.json
Binding convention (SweetMetal): set 0 binding N = vertex Metal buffer N (UBO), set 1 binding N = fragment
Metal buffer N (UBO), set 2 binding N = fragment texture N, set 3 binding N = fragment sampler N (16 + k for
the k-th constexpr sampler; res.json gives its Metal encoding). Vertex attribute location = Metal attribute
index. Varyings: location = index of the vertex output in the vertex function's output list. Metal clip
space is y-up: the vertex shader flips y. Half precision is computed as float.

Buffers are read as words of a uvec4 array (std140), so any layout and alignment works. Supported: the
arithmetic, vector, aggregate and control-flow instructions CA's shaders use after specialisation (acyclic
CFGs, structured with reach flags), and the air.* intrinsics in INTRINSICS / sample_texture_2d/3d.
"""
import json, os, re, struct, sys

class Unsupported(Exception):
    pass

# ---- types ----

def split_top(s, sep=','):
    """Split at top-level separators (outside <>, {}, (), [])."""
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '<{([':
            depth += 1
        elif ch in '>})]':
            depth -= 1
        if ch == sep and depth == 0:
            out.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out

def parse_type(t):
    """('scalar', 'f'|'i1'|'i'|'ptr', bits) | ('vec', n, elem) | ('struct', [members]) | ('array', n, elem)"""
    t = t.strip()
    if t.startswith('<{') or t.startswith('{'):
        inner = t[2:-2] if t.startswith('<{') else t[1:-1]
        return ('struct', [parse_type(x) for x in split_top(inner)])
    m = re.match(r'^<(\d+) x (.+)>$', t)
    if m:
        return ('vec', int(m.group(1)), parse_type(m.group(2)))
    m = re.match(r'^\[(\d+) x (.+)\]$', t)
    if m:
        return ('array', int(m.group(1)), parse_type(m.group(2)))
    if t in ('half', 'float', 'double'):
        return ('scalar', 'f', {'half': 16, 'float': 32, 'double': 64}[t])
    if t == 'i1':
        return ('scalar', 'b', 1)
    m = re.match(r'^i(\d+)$', t)
    if m:
        return ('scalar', 'i', int(m.group(1)))
    if t.startswith('ptr'):
        m = re.search(r'addrspace\((\d+)\)', t)
        return ('scalar', 'ptr', int(m.group(1)) if m else 0)
    raise Unsupported('type ' + t)

def glsl_type(ty):
    if ty[0] == 'scalar':
        return {'f': 'float', 'b': 'bool', 'i': 'int'}.get(ty[1]) or Unsupported('glsl type %r' % (ty,))
    if ty[0] == 'vec':
        n, e = ty[1], ty[2]
        if n == 1:
            return glsl_type(e)
        if n > 4:       # no such vector in GLSL: an array (loads, indexing and shuffles work on it)
            return '%s[%d]' % (glsl_type(e), n)
        return {'f': 'vec', 'b': 'bvec', 'i': 'ivec'}[e[1]] + str(n)
    raise Unsupported('glsl type %r' % (ty,))

def take_type(s):
    """Split 'TYPE rest' -> (TYPE, rest) for a leading LLVM type."""
    s = s.strip()
    if s[0] in '<{[':
        depth = 0
        for i, ch in enumerate(s):
            if ch in '<{[(':
                depth += 1
            elif ch in '>}])':
                depth -= 1
                if depth == 0:
                    end = i + 1
                    if s[0] == '<' and s[1] == '{':
                        pass
                    return s[:end], s[end:].strip()
    m = re.match(r'^(ptr(?: addrspace\(\d+\))?|half|float|double|i\d+|void)(?=[\s,]|$)(.*)$', s)
    if m:
        return m.group(1), m.group(2).strip()
    raise Unsupported('type in ' + s[:60])

# ---- constants ----

def fconst(tok):
    tok = tok.strip()
    if tok in ('poison', 'undef', 'zeroinitializer'):
        return '0.0'
    m = re.match(r'^f0x([0-9A-Fa-f]+)$', tok)     # exact bit pattern (newer LLVM)
    if m:
        h = m.group(1)
        if len(h) <= 4:
            return glsl_float(half_to_float(int(h, 16)))
        if len(h) <= 8:
            return glsl_float(struct.unpack('>f', bytes.fromhex(h.rjust(8, '0')))[0])
        return glsl_float(struct.unpack('>d', bytes.fromhex(h.rjust(16, '0')))[0])
    if tok.startswith('0xH'):
        return glsl_float(half_to_float(int(tok[3:], 16)))
    if tok.startswith('0x'):
        return glsl_float(struct.unpack('>d', bytes.fromhex(tok[2:].rjust(16, '0')))[0])
    if tok in ('+qnan', '-qnan', 'qnan', '+nan', 'nan'):
        return 'uintBitsToFloat(0x7fc00000u)'
    if tok in ('+inf', 'inf'):
        return 'uintBitsToFloat(0x7f800000u)'
    if tok == '-inf':
        return 'uintBitsToFloat(0xff800000u)'
    return glsl_float(float(tok))

def half_to_float(h):
    return struct.unpack('<e', struct.pack('<H', h))[0]

def glsl_float(v):
    if v != v:
        return 'uintBitsToFloat(0x7fc00000u)'
    if v in (float('inf'), float('-inf')):
        return 'uintBitsToFloat(%s)' % ('0x7f800000u' if v > 0 else '0xff800000u')
    r = repr(float(v))
    if 'e' not in r and '.' not in r:
        r += '.0'
    return r

def const_expr(ty, tok):
    tok = tok.strip()
    if ty[0] == 'scalar':
        if ty[1] == 'f':
            return fconst(tok)
        if ty[1] == 'b':
            return {'true': 'true', 'false': 'false'}.get(tok, 'false')
        if ty[1] == 'i':
            return '0' if tok in ('poison', 'undef', 'zeroinitializer') else str(int(tok))
    if ty[0] == 'vec':
        n, e = ty[1], ty[2]
        gt = glsl_type(ty)
        if tok in ('poison', 'undef', 'zeroinitializer'):
            return '%s(%s)' % (gt, const_expr(e, 'zeroinitializer'))
        m = re.match(r'^splat \((.+)\)$', tok)
        if m:
            et, v = take_type(m.group(1))
            return '%s(%s)' % (gt, const_expr(e, v))
        if tok.startswith('<'):
            parts = split_top(tok[1:-1])
            vals = []
            for p in parts:
                et, v = take_type(p)
                vals.append(const_expr(e, v))
            return '%s(%s)' % (gt, ', '.join(vals)) if n > 1 else vals[0]
    raise Unsupported('constant %s %r' % (tok, ty))

# ---- function parsing ----

def parse_metadata(text):
    return dict(re.findall(r'^(![0-9]+) = (?:distinct )?(.*)$', text, re.M))

def md_list(md, ref):
    v = md[ref]
    return re.findall(r'![0-9]+|![a-z.]+|!"[^"]*"|i32 -?\d+', v)

def md_entries(md, ref):
    """Tokens of a metadata node: strings without quotes, ints, refs."""
    out = []
    for tok in re.findall(r'!"[^"]*"|i\d+ -?\d+|![0-9]+', md[ref]):
        if tok.startswith('!"'):
            out.append(tok[2:-1])
        elif tok.startswith('i'):
            out.append(int(tok.split()[1]))
        else:
            out.append(tok)
    return out

class Func:
    def __init__(self, text):
        self.text = text
        m = re.search(r'^define (.*?) @([\w.]+)\((.*)\) local_unnamed_addr[^{]*\{$', text, re.M)
        if not m:
            m = re.search(r'^define (.*?) @([\w.]+)\((.*)\)[^{]*\{$', text, re.M)
        rt = m.group(1)
        for kw in ('internal ', 'dso_local ', 'noundef ', 'fastcc '):
            rt = rt.replace(kw, '')
        self.ret = parse_type(rt.strip())
        self.name = m.group(2)
        self.params = []
        for p in split_top(m.group(3)):
            t, rest = take_type(p)
            self.params.append((parse_type(t), rest.split()[-1]))
        body = text[m.end():text.index('\n}', m.end())]
        self.blocks = []        # [(label, [lines])]
        label, lines = '%entry', []
        first = True
        for line in body.split('\n'):
            s = line.split(';')[0].rstrip() if not line.strip().startswith(';') else ''
            lm = re.match(r'^(\d+|[\w.]+):', line)
            if lm:
                if lines or not first:
                    self.blocks.append((label, lines))
                label, lines, first = '%' + lm.group(1), [], False
                continue
            if s.strip():
                lines.append(s.strip())
                first = False
        self.blocks.append((label, lines))
        if self.blocks[0][0] == '%entry':
            # the entry block is unnamed: LLVM numbers it after the params
            self.blocks[0] = ('%' + str(len(self.params)), self.blocks[0][1])
        self.md = parse_metadata(text)
        stage = re.search(r'^!air\.(vertex|fragment) = !\{(![0-9]+)\}', text, re.M)
        self.stage = stage.group(1)
        root = md_entries(self.md, stage.group(2))
        self.out_md = [md_entries(self.md, r) for r in md_entries(self.md, root[0])] if root[0] != '!{}' else []
        self.arg_md = [md_entries(self.md, r) for r in md_entries(self.md, root[1])]
        self.globals = {}
        for gm in re.finditer(r'^(@[\w.]+) = .*?constant (i64|i32) (-?\d+)', text, re.M):
            self.globals[gm.group(1)] = int(gm.group(3))

# ---- translation ----

class Translator:
    def __init__(self, f, varyings=None):
        self.f = f
        self.vals = {}          # %name -> (expr or var name, type)
        self.decls = []         # function-scope declarations
        self.code = []          # statements (block structured)
        self.ptrs = {}          # %name -> (kind, index, byte offset)   kind: ubo | tex | smp | null
        self.ubos = {}          # metal index -> size
        self.texs = {}          # metal index -> '2d' | '3d'
        self.smps = {}          # binding -> constexpr value (None: an argument sampler)
        self.inputs = []        # GLSL declarations
        self.outputs = []
        self.used = set()
        self.varyings = varyings if varyings is not None else []
        self.tmp = 0
        self.set_base = 0 if f.stage == 'vertex' else 1
        self.uses_fbfetch = False
        self.dest = 0           # the colour attachment the fragment shader's output goes to (CA's dest_index)

    def new(self, gt, expr=None):
        self.tmp += 1
        n = 't%d' % self.tmp
        self.decls.append('%s %s;' % (gt, n))
        if expr is not None:
            self.code.append('%s = %s;' % (n, expr))
        return n

    def var(self, name, ty):
        n = 'v_' + name[1:].replace('.', '_')
        if ty[0] == 'struct':
            return [self.var(name + '.%d' % i, m) for i, m in enumerate(ty[1])]
        if n not in self.used:
            self.used.add(n)
            self.decls.append('%s %s;' % (glsl_type(ty), n))
        return n

    def operand(self, ty, tok):
        tok = tok.strip()
        if tok.startswith('%'):
            if tok in self.vals:
                return self.vals[tok][0]
            raise Unsupported('value %s used before definition' % tok)
        if ty[0] == 'struct':
            if tok in ('poison', 'undef', 'zeroinitializer'):
                return [self.operand(m, 'zeroinitializer') for m in ty[1]]
            inner = tok[2:-2] if tok.startswith('<{') else tok[1:-1]
            return [self.operand(m, take_type(p)[1]) for m, p in zip(ty[1], split_top(inner))]
        return const_expr(ty, tok)

    def typed_operand(self, s):
        t, v = take_type(s)
        ty = parse_type(t)
        return ty, (self.ptr(v) if ty[0] == 'scalar' and ty[1] == 'ptr' else self.operand(ty, v))

    def ptr(self, tok):
        tok = tok.strip()
        if tok in self.ptrs:
            return self.ptrs[tok]
        if tok.startswith('@'):
            return ('global', tok, 0)
        raise Unsupported('pointer ' + tok)

    # ---- arguments ----
    def setup_args(self):
        f = self.f
        for i, (ty, name) in enumerate(f.params):
            md = next((m for m in f.arg_md if m and m[0] == i), None)
            if md is None:
                continue
            role = next((x for x in md if isinstance(x, str) and x.startswith('air.') and x not in
                         ('air.function_constant', 'air.arg_type_name', 'air.arg_name', 'air.location_index',
                          'air.read', 'air.address_space', 'air.arg_type_size', 'air.arg_type_align_size',
                          'air.buffer_size', 'air.struct_type_info', 'air.center', 'air.perspective',
                          'air.no_perspective', 'air.flat', 'air.sample')), None)
            loc = md[md.index('air.location_index') + 1] if 'air.location_index' in md else None
            gt = glsl_type(ty) if ty[0] != 'scalar' or ty[1] != 'ptr' else None
            if role == 'air.vertex_input':
                self.vals[name] = ('in_%d' % loc, ty)
                self.inputs.append((name, 'layout(location = %d) in %s in_%d;' % (loc, gt, loc)))
            elif role == 'air.position':
                self.vals[name] = ('gl_FragCoord', ty)
            elif role == 'air.point_coord':
                self.vals[name] = ('vec2(gl_PointCoord)', ty)
            elif role == 'air.fragment_input':
                gen = md[md.index('air.fragment_input') + 1]
                if gen not in self.varyings:
                    self.varyings.append(gen)
                k = self.varyings.index(gen)
                q = 'flat ' if 'air.flat' in md else 'noperspective ' if 'air.no_perspective' in md else ''
                self.vals[name] = ('vary_%d' % k, ty)
                self.inputs.append((name, 'layout(location = %d) %sin %s vary_%d;' % (k, q, gt, k)))
            elif role == 'air.buffer':
                size = md[md.index('air.buffer_size') + 1] if 'air.buffer_size' in md else None
                self.ptrs[name] = ('ubo', loc, 0)
                self.ubos.setdefault(loc, size)
            elif role == 'air.texture':
                kind = '3d' if 'texture3d' in md[md.index('air.arg_type_name') + 1] else '2d'
                self.ptrs[name] = ('tex', loc, 0)
                self.texs[loc] = kind
            elif role == 'air.sampler':
                self.ptrs[name] = ('smp', loc, 0)
            elif role == 'air.render_target':
                # framebuffer fetch input (the current colour of attachment N): attachment 0 is read as a
                # texture (set 2 binding 15, sampler 23) at the fragment's pixel; SweetMetal flushes first
                n = md[md.index('air.render_target') + 1]
                self.vals[name] = ('fbfetch_%d' % n, ty)
            elif role in ('air.vertex_id', 'air.instance_id'):
                self.vals[name] = ('gl_VertexIndex' if role == 'air.vertex_id' else 'gl_InstanceIndex', ty)
            else:
                self.vals[name] = ('/*unsupported %s*/0' % role, ty)

    # ---- buffer loads ----
    def word(self, p, o):
        """The 32-bit word at absolute byte offset o (a multiple of 4, or an int expression) of p's buffer."""
        kind, idx, _ = p
        if kind != 'ubo':
            raise Unsupported('load from %s' % kind)
        k = '_max%d' % idx
        self.ubos.setdefault(idx, None)
        if isinstance(o, str):
            # dynamic: the whole buffer may be read (its declared size, else 4 KB)
            self.ubos[k] = max(self.ubos.get(k, 0), self.ubos.get(idx) or 4096)
            return 'ub%d_%d.w[(%s) >> 4][((%s) >> 2) & 3]' % (self.set_base, idx, o, o)
        self.ubos[k] = max(self.ubos.get(k, 0), o + 4)
        return 'ub%d_%d.w[%d][%d]' % (self.set_base, idx, o >> 4, (o >> 2) & 3)

    def load_scalar(self, p, off, ety):
        if isinstance(p[2], str):
            o = '(%s + %d)' % (p[2], off)
            w = self.word(p, o)
            if ety[2] >= 32:
                return ('uintBitsToFloat(%s)' if ety[1] == 'f' else 'int(%s)') % w
            if ety[1] == 'f' and ety[2] == 16:
                return 'unpackHalf2x16(%s)[((%s) >> 1) & 1]' % (w, o)
            if ety[1] in ('i', 'b') and ety[2] in (1, 8, 16):
                bits = 8 if ety[2] == 1 else ety[2]
                e = 'int((%s >> (uint((%s) & 3) * 8u)) & %du)' % (w, o, (1 << bits) - 1)
                return '(%s != 0)' % e if ety[1] == 'b' else e
            raise Unsupported('dynamic load of %r' % (ety,))
        o = p[2] + off
        w = self.word(p, o & ~3)
        if ety[1] == 'f' and ety[2] == 32:
            return 'uintBitsToFloat(%s)' % w
        if ety[1] == 'f' and ety[2] == 16:
            return 'unpackHalf2x16(%s).%s' % (w, 'y' if o & 2 else 'x')
        if ety[1] == 'i' and ety[2] == 32:
            return 'int(%s)' % w
        if ety[1] in ('i', 'b') and ety[2] in (1, 8, 16):
            bits = 8 if ety[2] == 1 else ety[2]
            e = 'int((%s >> %du) & %du)' % (w, (o & 3) * 8, (1 << bits) - 1)
            return '(%s != 0)' % e if ety[1] == 'b' else e
        raise Unsupported('load of %r' % (ety,))

    def load(self, ty, p):
        if ty[0] == 'scalar':
            return self.load_scalar(p, 0, ty)
        if ty[0] == 'vec':
            n, e = ty[1], ty[2]
            step = e[2] // 8
            parts = [self.load_scalar(p, k * step, e) for k in range(n)]
            return parts[0] if n == 1 else '%s(%s)' % (glsl_type(ty), ', '.join(parts))
        raise Unsupported('load of %r' % (ty,))

    # ---- instructions ----
    def emit_block(self, lines, label, succ_phis):
        for line in lines:
            if line.startswith('store '):
                continue        # function-constant predicate globals
            if line.startswith('br ') or line.startswith('ret ') or line == 'unreachable':
                self.term = line
                continue
            m = re.match(r'^(%[\w.]+) = (.*)$', line)
            if not m:
                raise Unsupported('line: ' + line)
            self.instr(m.group(1), m.group(2))

    def assign(self, dst, ty, expr):
        if ty[0] == 'struct':
            vs = self.var(dst, ty)
            for v, e in zip(vs, expr):
                self.code.append('%s = %s;' % (v, e) if isinstance(v, str) else None)
            self.vals[dst] = (vs, ty)
            return
        v = self.var(dst, ty)
        self.code.append('%s = %s;' % (v, expr))
        self.vals[dst] = (v, ty)

    def instr(self, dst, rhs):
        rhs = re.sub(r'^(tail |musttail |notail )', '', rhs)
        rhs = re.sub(r',?\s*!\w+ !\d+', '', rhs)
        rhs = re.sub(r'\s+#\d+$', '', rhs)
        op = rhs.split()[0]
        rest = rhs[len(op):].strip()
        # fast-math and wrap flags
        while True:
            w = rest.split()[0] if rest else ''
            if w in ('fast', 'nnan', 'ninf', 'nsz', 'arcp', 'contract', 'afn', 'reassoc', 'nuw', 'nsw', 'exact',
                     'inbounds', 'disjoint', 'nneg', 'samesign'):
                rest = rest[len(w):].strip()
            else:
                break
        if op in ('fadd', 'fsub', 'fmul', 'fdiv', 'add', 'sub', 'mul', 'and', 'or', 'xor', 'shl', 'lshr', 'ashr',
                  'sdiv', 'udiv', 'frem'):
            t, r = take_type(rest)
            ty = parse_type(t)
            a, b = split_top(r)
            a, b = self.operand(ty, a), self.operand(ty, b)
            sym = {'fadd': '+', 'fsub': '-', 'fmul': '*', 'fdiv': '/', 'add': '+', 'sub': '-', 'mul': '*',
                   'sdiv': '/', 'shl': '<<', 'ashr': '>>'}.get(op)
            base = ty if ty[0] == 'scalar' else ty[2]
            if base[1] == 'b' and op in ('and', 'or', 'xor'):
                if ty[0] == 'scalar':
                    e = '(%s %s %s)' % (a, {'and': '&&', 'or': '||', 'xor': '^^'}[op], b)
                else:
                    e = {'and': 'bvec%d(uvec%d(%s) & uvec%d(%s))', 'or': 'bvec%d(uvec%d(%s) | uvec%d(%s))',
                         'xor': 'notEqual(%s, %s)'}[op]
                    e = e % ((ty[1], ty[1], a, ty[1], b) if op != 'xor' else (a, b))
            elif op in ('and', 'or', 'xor'):
                e = '(%s %s %s)' % (a, {'and': '&', 'or': '|', 'xor': '^'}[op], b)
            elif op == 'lshr':
                e = 'int(uint(%s) >> uint(%s))' % (a, b)
            elif op == 'udiv':
                e = 'int(uint(%s) / uint(%s))' % (a, b)
            elif op == 'frem':
                e = '(%s - %s * trunc(%s / %s))' % (a, b, a, b)
            else:
                e = '(%s %s %s)' % (a, sym, b)
            self.assign(dst, ty, e)
        elif op == 'fneg':
            ty, a = self.typed_operand(rest)
            self.assign(dst, ty, '(-%s)' % a)
        elif op in ('fcmp', 'icmp'):
            pred, r = rest.split(None, 1)
            t, r = take_type(r)
            ty = parse_type(t)
            a, b = [self.operand(ty, x) for x in split_top(r)]
            p = pred.lstrip('ou') if pred not in ('one', 'une', 'ord', 'uno', 'true', 'false') else pred
            if pred in ('one', 'une', 'ne'):
                p = 'ne'
            rty = ('scalar', 'b', 1) if ty[0] == 'scalar' else ('vec', ty[1], ('scalar', 'b', 1))
            if pred in ('ord', 'uno', 'true', 'false'):
                v = {'ord': 'true', 'uno': 'false', 'true': 'true', 'false': 'false'}[pred]
                self.assign(dst, rty, v if ty[0] == 'scalar' else 'bvec%d(%s)' % (ty[1], v))
                return
            p = {'eq': 'eq', 'ne': 'ne', 'gt': 'gt', 'ge': 'ge', 'lt': 'lt', 'le': 'le', 'sgt': 'gt', 'sge': 'ge',
                 'slt': 'lt', 'sle': 'le', 'ugt': 'gt', 'uge': 'ge', 'ult': 'lt', 'ule': 'le'}.get(p, p)
            if pred.startswith('u') and op == 'icmp' and pred not in ('une',):
                a, b = 'uint(%s)' % a, 'uint(%s)' % b
            if ty[0] == 'scalar':
                e = '(%s %s %s)' % (a, {'eq': '==', 'ne': '!=', 'gt': '>', 'ge': '>=', 'lt': '<', 'le': '<='}[p], b)
            else:
                e = '%s(%s, %s)' % ({'eq': 'equal', 'ne': 'notEqual', 'gt': 'greaterThan', 'ge': 'greaterThanEqual',
                                     'lt': 'lessThan', 'le': 'lessThanEqual'}[p], a, b)
            self.assign(dst, rty, e)
        elif op == 'select':
            parts = split_top(rest)
            cty, c = self.typed_operand(parts[0])
            ty, a = self.typed_operand(parts[1])
            _, b = self.typed_operand(parts[2])
            if cty[0] == 'scalar':
                self.assign(dst, ty, '(%s ? %s : %s)' % (c, a, b))
            else:
                self.assign(dst, ty, 'mix(%s, %s, %s)' % (b, a, c))
        elif op == 'extractelement':
            parts = split_top(rest)
            vty, v = self.typed_operand(parts[0])
            _, i = self.typed_operand(parts[1])
            self.assign(dst, vty[2], '%s[%s]' % (v, i) if vty[1] > 1 else v)
        elif op == 'insertelement':
            parts = split_top(rest)
            vty, v = self.typed_operand(parts[0])
            _, x = self.typed_operand(parts[1])
            _, i = self.typed_operand(parts[2])
            if vty[1] == 1:
                self.assign(dst, vty, x)
                return
            n = self.var(dst, vty)
            self.code.append('%s = %s;' % (n, v))
            self.code.append('%s[%s] = %s;' % (n, i, x))
            self.vals[dst] = (n, vty)
        elif op == 'shufflevector':
            parts = split_top(rest)
            aty, a = self.typed_operand(parts[0])
            _, b = self.typed_operand(parts[1])
            mt, mv = take_type(parts[2])
            mty = parse_type(mt)
            n = aty[1]
            if mv == 'zeroinitializer':
                mask = [0] * mty[1]
            elif mv.startswith('splat'):
                mask = [int(re.search(r'(-?\d+)\)$', mv).group(1))] * mty[1]
            else:
                mask = []
                for p in split_top(mv[1:-1]):
                    x = p.split()[-1]
                    mask.append(-1 if x in ('poison', 'undef') else int(x))
            ety = aty[2]
            comps = []
            for k in mask:
                if k < 0:
                    comps.append(const_expr(ety, 'zeroinitializer'))
                elif k < n:
                    comps.append('%s[%d]' % (a, k) if n > 1 else a)
                else:
                    comps.append('%s[%d]' % (b, k - n) if n > 1 else b)
            rty = ('vec', len(mask), ety)
            self.assign(dst, rty, comps[0] if len(mask) == 1 else '%s(%s)' % (glsl_type(rty), ', '.join(comps)))
        elif op == 'extractvalue':
            parts = split_top(rest)
            sty, s = self.typed_operand(parts[0])
            idx = [int(x) for x in parts[1:]]
            for i in idx:
                s, sty = s[i], sty[1][i]
            self.assign(dst, sty, s)
        elif op == 'insertvalue':
            parts = split_top(rest)
            sty, s = self.typed_operand(parts[0])
            ety, x = self.typed_operand(parts[1])
            idx = [int(x_) for x_ in parts[2:]]
            if len(idx) != 1:
                raise Unsupported('nested insertvalue')
            vs = self.var(dst, sty)
            for k, v in enumerate(vs):
                self.code.append('%s = %s;' % (v, x if k == idx[0] else s[k]))
            self.vals[dst] = (vs, sty)
        elif op == 'phi':
            t, r = take_type(rest)
            ty = parse_type(t)
            v = self.var(dst, ty)
            self.vals[dst] = (v, ty)
            # assignments are made on the incoming edges (see emit)
        elif op == 'getelementptr':
            parts = split_top(rest)
            et = parts[0]
            pty, p = self.typed_operand(parts[1])
            esize = type_size(parse_type(et))
            if len(parts) != 3:
                raise Unsupported('GEP into aggregate')
            ity, iv = take_type(parts[2])
            if re.match(r'^-?\d+$', iv):
                off = int(iv) * esize
                self.ptrs[dst] = (p[0], p[1], p[2] + off if isinstance(p[2], int) else '(%s + %d)' % (p[2], off))
            else:
                ix = self.operand(parse_type(ity), iv)
                self.ptrs[dst] = (p[0], p[1], '(%s + int(%s) * %d)' % (p[2], ix, esize))
        elif op == 'load':
            parts = split_top(rest)
            ty = parse_type(parts[0])
            _, p = self.typed_operand(parts[1])
            if p[0] == 'global':
                raise Unsupported('load from global %s' % p[1])
            self.assign(dst, ty, self.load(ty, p))
        elif op in ('fpext', 'fptrunc', 'bitcast', 'zext', 'sext', 'trunc', 'sitofp', 'uitofp', 'fptosi', 'fptoui'):
            m = re.match(r'^(.*) to (.+)$', rest)
            sty, a = self.typed_operand(m.group(1))
            ty = parse_type(m.group(2))
            gt = glsl_type(ty)
            if op in ('fpext', 'fptrunc'):
                e = a
            elif op == 'bitcast':
                raise Unsupported('bitcast')
            elif op in ('zext', 'sext') and (sty[1] == 'b' or (sty[0] == 'vec' and sty[2][1] == 'b')):
                e = '%s(%s)' % (gt, a) if op == 'zext' else '(-%s(%s))' % (gt, a)
            elif op in ('zext', 'sext', 'trunc'):
                bits = (ty if ty[0] == 'scalar' else ty[2])[2]
                sbits = (sty if sty[0] == 'scalar' else sty[2])[2]
                e = a if bits >= 32 or op != 'trunc' else '(%s & %d)' % (a, (1 << bits) - 1)
                if op == 'sext' and sbits < 32:
                    e = '((%s << %d) >> %d)' % (a, 32 - sbits, 32 - sbits)
                if bits == 1:
                    e = '(%s & 1) != 0' % a
            elif op == 'uitofp':
                e = '%s(%s(%s))' % (gt, 'uint' if sty[0] == 'scalar' else 'uvec%d' % sty[1], a)
            else:
                e = '%s(%s)' % (gt, a)
            self.assign(dst, ty, e)
        elif op == 'call':
            self.call(dst, rest)
        else:
            raise Unsupported('instruction ' + op)

    def call(self, dst, rest):
        t, r = take_type(rest)
        rty = parse_type(t) if t != 'void' else None
        m = re.match(r'^@([\w.]+)\((.*)\)$', r)
        fn, args = m.group(1), split_top(m.group(2))
        vals = []
        for a in args:
            a = re.sub(r'\b(readonly|captures\(none\)|noundef|nocapture|nonnull|readnone|writeonly|align \d+|'
                       r'dereferenceable\(\d+\))\s*', '', a)
            vals.append(self.typed_operand(a))
        base = re.sub(r'\.(v\d+)?[fiu]\d+$', '', fn)
        base = re.sub(r'\.(v\d+)?[fiu]\d+$', '', base)
        x = [v for _, v in vals]
        simple = {'air.fmax': 'max', 'air.fast_fmax': 'max', 'air.fmin': 'min', 'air.fast_fmin': 'min',
                  'air.fabs': 'abs', 'air.fast_fabs': 'abs', 'air.fma': 'fma', 'air.fast_fma': 'fma',
                  'air.clamp': 'clamp', 'air.fast_clamp': 'clamp', 'air.mix': 'mix', 'air.fast_mix': 'mix',
                  'air.dot': 'dot', 'air.fast_dot': 'dot', 'air.sqrt': 'sqrt', 'air.fast_sqrt': 'sqrt',
                  'air.rsqrt': 'inversesqrt', 'air.fast_rsqrt': 'inversesqrt', 'air.fwidth': 'fwidth',
                  'air.floor': 'floor', 'air.fast_floor': 'floor', 'air.ceil': 'ceil', 'air.fast_ceil': 'ceil',
                  'air.fract': 'fract', 'air.fast_fract': 'fract', 'air.exp2': 'exp2', 'air.fast_exp2': 'exp2',
                  'air.log2': 'log2', 'air.fast_log2': 'log2', 'air.pow': 'pow', 'air.fast_pow': 'pow',
                  'air.sin': 'sin', 'air.fast_sin': 'sin', 'air.cos': 'cos', 'air.fast_cos': 'cos',
                  'air.length': 'length', 'air.fast_length': 'length', 'air.normalize': 'normalize',
                  'air.fast_normalize': 'normalize', 'air.trunc': 'trunc', 'air.fast_trunc': 'trunc',
                  'air.rint': 'roundEven', 'air.fast_rint': 'roundEven', 'air.round': 'round',
                  'air.fast_round': 'round', 'air.dfdx': 'dFdx', 'air.dfdy': 'dFdy', 'air.step': 'step',
                  'air.fast_step': 'step', 'air.smoothstep': 'smoothstep', 'air.fast_smoothstep': 'smoothstep',
                  'air.sign': 'sign', 'air.fast_sign': 'sign', 'air.min': 'min', 'air.max': 'max',
                  'air.exp': 'exp', 'air.fast_exp': 'exp', 'air.log': 'log', 'air.fast_log': 'log',
                  'air.powr': 'pow', 'air.fast_powr': 'pow', 'air.tan': 'tan', 'air.fast_tan': 'tan',
                  'air.atan2': 'atan', 'air.fast_atan2': 'atan', 'air.atan': 'atan', 'air.fast_atan': 'atan',
                  'air.asin': 'asin', 'air.fast_asin': 'asin', 'air.acos': 'acos', 'air.fast_acos': 'acos',
                  'air.exp10': 'exp10', 'air.fast_exp10': 'exp10', 'air.log10': 'log10', 'air.fast_log10': 'log10',
                  'air.fmin3': 'min3', 'air.fmax3': 'max3', 'air.fmedian3': 'median3',
                  'llvm.fmuladd': 'fma', 'llvm.fma': 'fma', 'llvm.fabs': 'abs', 'llvm.minnum': 'min',
                  'llvm.maxnum': 'max', 'llvm.floor': 'floor', 'llvm.ceil': 'ceil', 'llvm.sqrt': 'sqrt',
                  'llvm.trunc': 'trunc', 'llvm.round': 'round', 'llvm.rint': 'roundEven', 'llvm.exp2': 'exp2',
                  'llvm.log2': 'log2', 'llvm.smin': 'min', 'llvm.smax': 'max'}
        if base in simple:
            self.assign(dst, rty, '%s(%s)' % (simple[base], ', '.join(x)))
        elif base == 'llvm.abs':       # (x, i1 int_min_is_poison)
            self.assign(dst, rty, 'abs(%s)' % x[0])
        elif base == 'llvm.copysign':
            if rty[0] == 'scalar' or rty[1] == 1:
                self.assign(dst, rty, '(%s < 0.0 ? -abs(%s) : abs(%s))' % (x[1], x[0], x[0]))
            else:
                self.assign(dst, rty, 'mix(abs(%s), -abs(%s), lessThan(%s, %s(0.0)))' % (x[0], x[0], x[1], glsl_type(rty)))
        elif base in ('air.get_width_texture_2d', 'air.get_height_texture_2d'):
            # (texture, lod): GL_EXT_samplerless_texture_functions
            tex = vals[0][1]
            if tex[0] != 'tex':
                raise Unsupported('size of %s' % (tex,))
            self.texs.setdefault(tex[1], '2d')
            self.uses_size = True
            self.assign(dst, rty, 'textureSize(tex_%d, int(%s)).%s' % (tex[1], x[1] if len(x) > 1 else '0',
                                                                       'x' if 'width' in base else 'y'))
        elif fn.startswith('llvm.vector.reduce.'):
            vty, v = vals[-1]
            o = {'fmul': '*', 'fadd': '+', 'mul': '*', 'add': '+', 'and': '&', 'or': '|'}[fn.split('.')[3]]
            terms = ['%s[%d]' % (v, i) for i in range(vty[1])]
            if len(vals) == 2:      # ordered reductions take a start value
                terms.insert(0, x[0])
            self.assign(dst, rty, '(' + (' %s ' % o).join(terms) + ')')
        elif base in ('air.saturate', 'air.fast_saturate'):
            self.assign(dst, rty, 'clamp(%s, 0.0, 1.0)' % x[0])
        elif base in ('air.any', 'air.all'):
            vty = vals[0][0]
            f = base[4:]
            self.assign(dst, rty, x[0] if vty[0] == 'scalar' or vty[1] == 1 else '%s(%s)' % (f, x[0]))
        elif fn.startswith('air.convert.'):
            # air.convert.<dst kind>.<dst type>.<src kind>.<src type>
            p = fn.split('.')
            dk, sk = p[2], p[4]
            gt = glsl_type(rty)
            a = x[0]
            n = rty[1] if rty[0] == 'vec' else 1
            if dk == 'u':
                e = '%s(%s(%s))' % (gt, 'uint' if n == 1 else 'uvec%d' % n, a)
            elif sk == 'u':
                e = '%s(%s(%s))' % (gt, 'uint' if n == 1 else 'uvec%d' % n, a)
            elif sk == 's' and re.match(r'^v?\d*i(8|16)$', p[5]):
                # narrow signed source: loads zero-extend, sign-extend first
                b = 32 - int(re.search(r'i(\d+)$', p[5]).group(1))
                e = '%s((%s << %d) >> %d)' % (gt, a, b, b)
            else:
                e = '%s(%s)' % (gt, a)
            self.assign(dst, rty, e)
        elif base in ('air.get_null_texture_2d', 'air.get_null_texture_3d', 'air.get_null_sampler'):
            self.ptrs[dst] = ('null', None, 0)
        elif fn.startswith('air.sample_texture_2d') or fn.startswith('air.sample_texture_3d'):
            tex, smp, coord = vals[0][1], vals[1][1], vals[2][1]
            if tex[0] != 'tex':
                raise Unsupported('sample of %s' % (tex,))
            three = '3d' in fn
            sname = self.sampler(smp)
            st = 'sampler3D' if three else 'sampler2D'
            s = '%s(tex_%d, %s)' % (st, tex[1], sname)
            # 2d: (tex, smp, coord, i1 ?, <2 x i32> offset, i1 lod, float bias_or_lod, float min_lod, i32)
            # 3d: (tex, smp, coord, i1 ?, <3 x i32> offset, i1 lod, float bias_or_lod, float min_lod, i32)
            is_lod = x[5] == 'true' if len(x) > 6 else False
            lb = x[6] if len(x) > 6 else '0.0'
            if is_lod:
                e = 'textureLod(%s, %s, %s)' % (s, coord, lb)
            elif lb in ('0.0', '-0.0'):
                e = 'texture(%s, %s)' % (s, coord)
            else:
                e = 'texture(%s, %s, %s)' % (s, coord, lb)
            if self.f.stage == 'vertex':
                e = 'textureLod(%s, %s, %s)' % (s, coord, lb if is_lod else '0.0')
            comps = rty[1]
            self.assign(dst, rty, [e, '0'] if len(comps) == 2 else [e])
        else:
            raise Unsupported('call ' + fn)

    def sampler(self, smp):
        if smp[0] == 'smp':
            self.smps.setdefault(smp[1], None)
            return 'smp_%d' % smp[1]
        if smp[0] == 'global':
            v = self.f.globals.get(smp[1])
            if v is None:
                raise Unsupported('sampler global ' + smp[1])
            for b, val in self.smps.items():
                if val == v:
                    return 'smp_%d' % b
            b = 16 + sum(1 for k in self.smps if k >= 16)
            self.smps[b] = v
            return 'smp_%d' % b
        raise Unsupported('sampler %r' % (smp,))

    # ---- control flow ----
    def translate(self):
        self.setup_args()
        f = self.f
        labels = [b[0] for b in f.blocks]
        order = {l: i for i, l in enumerate(labels)}
        # successors from terminators (parse first: phis need them)
        succ = {}
        for l, lines in f.blocks:
            t = next(x for x in reversed(lines) if x.startswith(('br ', 'ret ', 'unreachable', 'ret')))
            succ[l] = re.findall(r'label (%[\w.]+)', t)
            for s in succ[l]:
                if order[s] <= order[l]:
                    raise Unsupported('loop (back edge %s -> %s)' % (l, s))
        multi = len(f.blocks) > 1
        for l in labels:
            if multi and l != labels[0]:
                self.decls.append('bool r_%s = false;' % l[1:].replace('.', '_'))
        body = []
        for l, lines in f.blocks:
            self.code = []
            self.term = None
            self.emit_block(lines, l, None)
            t = self.term
            # phi assignments for each successor
            def edge(s):
                out = []
                sl = next(b for b in f.blocks if b[0] == s)[1]
                for line in sl:
                    m = re.match(r'^(%[\w.]+) = phi (.*)$', line)
                    if not m:
                        continue
                    ty_s, r = take_type(m.group(2))
                    ty = parse_type(ty_s)
                    for inc in re.findall(r'\[([^\]]*)\]', r):
                        v, frm = split_top(inc)
                        if frm.strip() == l:
                            out.append('%s = %s;' % (self.var(m.group(1), ty), self.operand(ty, v)))
                out.append('r_%s = true;' % s[1:].replace('.', '_'))
                return out
            if t.startswith('br i1'):
                m = re.match(r'^br i1 ([^,]+), label (%[\w.]+), label (%[\w.]+)$', t)
                c = self.operand(('scalar', 'b', 1), m.group(1))
                self.code.append('if (%s) { %s } else { %s }' % (c, ' '.join(edge(m.group(2))), ' '.join(edge(m.group(3)))))
            elif t.startswith('br label'):
                self.code += edge(re.match(r'^br label (%[\w.]+)$', t).group(1))
            elif t.startswith('ret'):
                self.code += self.ret(t)
            if multi and l != labels[0]:
                body.append('if (r_%s) {' % l[1:].replace('.', '_'))
                body += ['\t' + c for c in self.code]
                body.append('}')
            else:
                body += self.code
        return body

    def ret(self, t):
        f = self.f
        if t == 'ret void':
            return []
        ty, v = self.typed_operand(t[4:])
        comps = v if isinstance(v, list) else [v]
        out = []
        for k, md in enumerate(f.out_md):
            if k >= len(comps):
                break
            c = comps[k]
            if 'air.position' in md:
                out.append('gl_Position = %s;' % c)
                out.append('gl_Position.y = -gl_Position.y;')
            elif 'air.vertex_output' in md:
                gen = md[md.index('air.vertex_output') + 1]
                if gen not in self.varyings:
                    self.varyings.append(gen)
                n = self.varyings.index(gen)
                gt = glsl_type(ty[1][k] if ty[0] == 'struct' else ty)
                self.outputs.append('layout(location = %d) out %s vary_%d;' % (n, gt, n))
                out.append('vary_%d = %s;' % (n, c))
            elif 'air.render_target' in md:
                rt = md[md.index('air.render_target') + 1]
                if rt == self.dest:     # the attachment this pipeline writes: drawn as location 0
                    self.outputs.append('layout(location = 0) out vec4 frag_0;')
                    out.append('frag_0 = vec4(%s);' % c)
            elif 'air.depth' in md:
                out.append('gl_FragDepth = %s;' % c)
        if f.ret[0] != 'struct' and f.out_md:
            pass
        return out

def type_size(ty):
    if ty[0] == 'scalar':
        return max(ty[2] // 8, 1) if ty[1] != 'ptr' else 8
    if ty[0] == 'vec':
        n = ty[1] if ty[1] != 3 else 4
        return n * type_size(ty[2])
    if ty[0] == 'array':
        return ty[1] * type_size(ty[2])
    raise Unsupported('size of struct')

def emit(tr, body):
    f = tr.f
    lines = ['#version 450', '#extension GL_EXT_samplerless_texture_functions : require', '// %s (air2glsl.py)' % f.name,
             '#define exp10(x) exp2((x) * 3.32192809)', '#define log10(x) (log2(x) * 0.30103)',
             '#define min3(a, b, c) min(min(a, b), c)', '#define max3(a, b, c) max(max(a, b), c)',
             '#define median3(a, b, c) max(min(a, b), min(max(a, b), c))']
    used_text = '\n'.join(body)
    for name, d in tr.inputs:
        var = re.search(r' (\w+);$', d).group(1)
        if re.search(r'\b%s\b' % var, used_text):
            lines.append(d)
    lines += sorted(set(tr.outputs))
    s = tr.set_base
    for idx in sorted(k for k in tr.ubos if not str(k).startswith('_')):
        mx = tr.ubos.get('_max%d' % idx, 0)
        if not mx:
            continue
        n = max((mx + 15) // 16, 1)
        lines.append('layout(set = %d, binding = %d, std140) uniform U%d_%d { uvec4 w[%d]; } ub%d_%d;' % (s, idx, s, idx, n, s, idx))
    for idx, kind in sorted(tr.texs.items()):
        if re.search(r'\btex_%d\b' % idx, used_text):
            lines.append('layout(set = 2, binding = %d) uniform texture%s tex_%d;' % (idx, kind.upper(), idx))
    for b in sorted(tr.smps):
        lines.append('layout(set = 3, binding = %d) uniform sampler smp_%d;' % (b, b))
    # framebuffer fetch: attachment 0 = texture 15, attachment 1 (CA's memoryless one) = texture 14
    fetch = sorted(set(int(n) for n in re.findall(r'\bfbfetch_(\d+)\b', used_text)))
    if any(n > 1 for n in fetch):
        raise Unsupported('framebuffer fetch of attachment %s' % fetch)
    for n in fetch:
        lines.append('layout(set = 2, binding = %d) uniform texture2D tex_fb%d;' % (15 - n, n))
    if fetch:
        lines.append('layout(set = 3, binding = 23) uniform sampler smp_fb;')
    tr.fbfetch = fetch
    lines.append('void main()')
    lines.append('{')
    for n in fetch:
        lines.append('\tvec4 fbfetch_%d = texelFetch(sampler2D(tex_fb%d, smp_fb), ivec2(gl_FragCoord.xy), 0);' % (n, n))
    lines += ['\t' + d for d in tr.decls]
    lines += ['\t' + c for c in body]
    lines.append('}')
    return '\n'.join(lines) + '\n'

def translate_pair(vs_text, fs_text, dest=0):
    vs = Translator(Func(vs_text))
    vbody = vs.translate()
    fs = Translator(Func(fs_text), varyings=vs.varyings)
    fs.dest = dest
    fbody = fs.translate()
    res = {'vs_ubos': {str(k): v for k, v in vs.ubos.items() if str(k).startswith('_max')},
           'fs_ubos': {str(k): v for k, v in fs.ubos.items() if str(k).startswith('_max')},
           'textures': {str(k): v for k, v in fs.texs.items()},
           'samplers': {str(k): v for k, v in fs.smps.items()}}
    res['vs_ubos'] = {k[4:]: v for k, v in res['vs_ubos'].items() if v}
    res['fs_ubos'] = {k[4:]: v for k, v in res['fs_ubos'].items() if v}
    vtext, ftext = emit(vs, vbody), emit(fs, fbody)
    if fs.fbfetch:
        res['fbfetch'] = fs.fbfetch
    if dest:
        res['dest'] = dest
    res['textures'] = {k: v for k, v in res['textures'].items() if re.search(r'\btex_%s\b' % k, ftext)}
    return vtext, ftext, res

if __name__ == '__main__':
    vtext, ftext, res = translate_pair(open(sys.argv[1]).read(), open(sys.argv[2]).read())
    os.makedirs(sys.argv[3], exist_ok=True)
    open(os.path.join(sys.argv[3], 'vs.vert'), 'w').write(vtext)
    open(os.path.join(sys.argv[3], 'fs.frag'), 'w').write(ftext)
    json.dump(res, open(os.path.join(sys.argv[3], 'res.json'), 'w'), indent=1)
    print(json.dumps(res))
