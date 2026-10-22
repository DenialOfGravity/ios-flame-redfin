/*
 * SweetMetal's GPU side (a6draw.h). A template (tools/rdtemplate.py export) holds turnip's commands for one
 * pipeline: the prologue (device + sysmem pass setup, as register writes and packets), the draw's state groups
 * and the epilogue (flushes), with named patch points for what changes: shader/global addresses (once per
 * pipeline), the render target (per pass), vertex buffers, descriptors, viewport and scissor (per draw).
 */
#import "a6draw.h"
#include <IOKit/IOKitLib.h>
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>

#define CP_SET_DRAW_STATE	0x43
#define CP_DRAW_INDX_OFFSET	0x38
#define STREAM_BYTES		(1u << 20)	/* IB and scratch per command stream */

static void glog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void glog(const char *fmt, ...)
{
	static int fd = -2;
	char buf[512];
	int n = snprintf(buf, sizeof(buf), "MTL[%d %s]: gpu: ", getpid(), getprogname());
	va_list ap;
	va_start(ap, fmt);
	n += vsnprintf(buf + n, sizeof(buf) - (size_t)n - 1, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof(buf) - 2)
		n = (int)sizeof(buf) - 2;
	buf[n++] = '\n';
	if (fd == -2)
		fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (fd >= 0)
		write(fd, buf, (size_t)n);
	static int file_fd = -2;	/* as SweetMetal.m's mlog: a file copy when /var/local/mtl.log exists */
	if (file_fd == -2)
		file_fd = open("/var/local/mtl.log", O_WRONLY | O_APPEND);
	if (file_fd >= 0)
		write(file_fd, buf, (size_t)n);
}

static NSData *hexdata(NSString *hex)
{
	NSData *src = [hex dataUsingEncoding:NSASCIIStringEncoding];
	NSUInteger n = src.length / 2;
	NSMutableData *d = [NSMutableData dataWithLength:n];
	uint8_t *p = d.mutableBytes;
	const uint8_t *s = src.bytes;
	for (NSUInteger i = 0; i < n; i++) {
		uint8_t a = s[2 * i], b = s[2 * i + 1];
		a = a <= '9' ? a - '0' : (a | 0x20) - 'a' + 10;
		b = b <= '9' ? b - '0' : (b | 0x20) - 'a' + 10;
		p[i] = (uint8_t)(a << 4 | b);
	}
	return d;
}

/* ---- the device ---- */

@implementation SweetGPU {
	struct sg_dev _dev;
	struct sg_bo _globals;
	BOOL _have_globals;
	NSMutableDictionary *_surfaces;	/* IOSurfaceID -> [sg_bo (NSData), the IOSurface (retained)] */
	unsigned _sweep;
	NSMutableArray *_streams;	/* free (ib, scratch) pairs: GPU VAs are not reused by the kernel */
}

+ (instancetype)shared
{
	static SweetGPU *g;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		SweetGPU *x = [SweetGPU new];
		if (sg_open(&x->_dev, 0) == 0) {
			x->_surfaces = [NSMutableDictionary new];
			x->_streams = [NSMutableArray new];
			g = x;
			glog("SweetAccelerator open (gpu %u)", x->_dev.gpu_id);
		} else {
			glog("no SweetAccelerator: drawing disabled");
		}
	});
	return g;
}

- (struct sg_dev *)dev
{
	return &_dev;
}

- (BOOL)alloc:(uint64_t)size bo:(struct sg_bo *)bo
{
	return sg_bo_alloc(&_dev, size, bo) == 0;
}

- (const struct sg_bo *)boForSurface:(IOSurfaceRef)s
{
	@synchronized(self) {
		return [self boForSurfaceLocked:s];
	}
}

- (const struct sg_bo *)boForSurfaceLocked:(IOSurfaceRef)s
{
	NSNumber *k = @(IOSurfaceGetID(s));
	NSArray *v = _surfaces[k];
	if (v && (__bridge IOSurfaceRef)v[1] == s)
		return [v[0] bytes];
	if (v)			/* the ID now names another surface */
		[self dropSurface:k];
	struct sg_bo bo;
	if (sg_surface_import(&_dev, IOSurfaceGetID(s), &bo)) {
		glog("surface %u: import failed", IOSurfaceGetID(s));
		return NULL;
	}
	_surfaces[k] = @[ [NSData dataWithBytes:&bo length:sizeof(bo)], (__bridge id)s ];
	return [_surfaces[k][0] bytes];
}

- (void)dropSurface:(NSNumber *)k
{
	struct sg_bo bo;
	memcpy(&bo, [_surfaces[k][0] bytes], sizeof(bo));
	sg_bo_free(&_dev, &bo);
	[_surfaces removeObjectForKey:k];
}

/* After a submit: release imports of surfaces nobody else holds any more (their GPU mappings go too). */
- (void)sweepSurfaces
{
	@synchronized(self) {
		if (++_sweep % 30)
			return;
		for (NSNumber *k in _surfaces.allKeys)
			if (CFGetRetainCount((__bridge CFTypeRef)_surfaces[k][1]) <= 1)
				[self dropSurface:k];
	}
}

- (uint64_t)scratchTargetVA:(uint64_t)bytes
{
	/* never freed: a queued draw may still use a smaller one; the first is full-screen sized */
	static struct sg_bo bo;
	if (bo.size < bytes) {
		uint64_t want = MAX(bytes, 4608ull * 2436);
		if (sg_bo_alloc(&_dev, (want + 0xffff) & ~0xffffull, &bo))
			memset(&bo, 0, sizeof(bo));
		glog("memoryless attachment buffer: %llu bytes at %llx", bo.size, bo.va);
	}
	return bo.va;
}

- (uint64_t)vaForSurface:(IOSurfaceRef)s
{
	const struct sg_bo *bo = [self boForSurface:s];
	return bo ? bo->va : 0;
}

/* turnip's global buffer (border colours, ...), from the first template loaded: the same for all */
- (uint64_t)globalsVA
{
	return _have_globals ? _globals.va : 0;
}

- (void)setGlobals:(NSData *)data
{
	if (_have_globals || ![self alloc:data.length bo:&_globals])
		return;
	memcpy(_globals.map, data.bytes, data.length);
	sg_cache_flush(&_dev, &_globals, 0, data.length);
	_have_globals = YES;
}

- (NSArray *)takeStream
{
	@synchronized(_streams) {
		if (_streams.count) {
			NSArray *s = _streams.lastObject;
			[_streams removeLastObject];
			return s;
		}
	}
	struct sg_bo ib, sc;
	if (![self alloc:STREAM_BYTES bo:&ib] || ![self alloc:STREAM_BYTES bo:&sc])
		return nil;
	return @[ [NSData dataWithBytes:&ib length:sizeof(ib)], [NSData dataWithBytes:&sc length:sizeof(sc)] ];
}

- (void)giveStream:(NSArray *)s
{
	if (s)
		@synchronized(_streams) {
			[_streams addObject:s];
		}
}
@end

/* ---- pipeline templates ---- */

struct tgroup {
	uint32_t hdr;			/* count | flags | id << 24, as captured */
	uint64_t va;			/* static groups: built once */
	uint32_t *dw;			/* dynamic groups: patched per draw */
	uint32_t ndw;
	uint32_t (*patch)[2];		/* (dword, name index) */
	uint32_t npatch;
};

enum pname {
	P_NONE, P_SHADER_LO, P_SHADER_HI, P_GLOBAL_LO, P_GLOBAL_HI, P_VB_LO, P_VB_HI, P_VB_SIZE, P_BL_LO, P_BL_HI,
	P_VP_XOFF, P_VP_XSCALE, P_VP_YOFF, P_VP_YSCALE, P_VPSC_TL, P_VPSC_BR, P_SCSC_TL, P_SCSC_BR,
	P_RT_INFO, P_RT_PITCH, P_RT_APITCH, P_RT_LO, P_RT_HI, P_RT_FLAG_LO, P_RT_FLAG_HI, P_RT_SPFMT, P_RT_LRZFMT,
	P_WINDOW_BR, P_A2D_BR,
};

/* "vb1.lo" -> P_VB_LO, arg 1; "shader.lo+1664" -> P_SHADER_LO, arg 1664 */
static enum pname parse_patch(NSString *s, uint32_t *arg)
{
	const char *p = s.UTF8String;
	unsigned n = 0;
	*arg = 0;
	if (sscanf(p, "shader.lo+%u", &n) == 1) { *arg = n; return P_SHADER_LO; }
	if (sscanf(p, "shader.hi+%u", &n) == 1) { *arg = n; return P_SHADER_HI; }
	if (sscanf(p, "global.lo+%u", &n) == 1) { *arg = n; return P_GLOBAL_LO; }
	if (sscanf(p, "global.hi+%u", &n) == 1) { *arg = n; return P_GLOBAL_HI; }
	char k[16] = { 0 };
	if (sscanf(p, "vb%u.%15s", &n, k) == 2) {
		*arg = n;
		return !strcmp(k, "lo") ? P_VB_LO : !strcmp(k, "hi") ? P_VB_HI : P_VB_SIZE;
	}
	if (sscanf(p, "bindless%u.%15s", &n, k) == 2) {
		*arg = n;
		return !strcmp(k, "lo") ? P_BL_LO : P_BL_HI;
	}
	static const struct { const char *s; enum pname p; } t[] = {
		{ "vp.xoff", P_VP_XOFF }, { "vp.xscale", P_VP_XSCALE }, { "vp.yoff", P_VP_YOFF }, { "vp.yscale", P_VP_YSCALE },
		{ "vpsc.tl", P_VPSC_TL }, { "vpsc.br", P_VPSC_BR }, { "scsc.tl", P_SCSC_TL }, { "scsc.br", P_SCSC_BR },
		{ "rt.info", P_RT_INFO }, { "rt.pitch", P_RT_PITCH }, { "rt.apitch", P_RT_APITCH }, { "rt.lo", P_RT_LO },
		{ "rt.hi", P_RT_HI }, { "rt.flag.lo", P_RT_FLAG_LO }, { "rt.flag.hi", P_RT_FLAG_HI },
		{ "rt.spfmt", P_RT_SPFMT }, { "rt.lrzfmt", P_RT_LRZFMT }, { "window.br", P_WINDOW_BR }, { "a2d.br", P_A2D_BR },
	};
	for (unsigned i = 0; i < sizeof(t) / sizeof(t[0]); i++)
		if (!strcmp(p, t[i].s))
			return t[i].p;
	return P_NONE;
}

static uint32_t fbits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}

/* What a patch point gets, given the captured value (some keep flag bits). */
struct pctx {
	uint64_t shader_va, globals_va;
	const struct sweet_target *t;
	const struct sweet_draw *d;
	uint64_t bindless[4];
};

static uint32_t patch_value(enum pname p, uint32_t arg, uint32_t orig, const struct pctx *c)
{
	const struct sweet_draw *d = c->d;
	const struct sweet_target *t = c->t;
	switch (p) {
	case P_SHADER_LO: return (uint32_t)(c->shader_va + arg);
	case P_SHADER_HI: return (uint32_t)((c->shader_va + arg) >> 32);
	case P_GLOBAL_LO: return (uint32_t)(c->globals_va + arg);
	case P_GLOBAL_HI: return (uint32_t)((c->globals_va + arg) >> 32);
	case P_VB_LO: return d && arg < 8 ? (uint32_t)d->vb_va[arg] : 0;
	case P_VB_HI: return d && arg < 8 ? (uint32_t)(d->vb_va[arg] >> 32) : 0;
	case P_VB_SIZE: return d && arg < 8 ? d->vb_size[arg] : 0;
	case P_BL_LO: return arg < 4 ? (uint32_t)c->bindless[arg] | (orig & 3) : orig;	/* low bits: descriptor size */
	case P_BL_HI: return arg < 4 ? (uint32_t)(c->bindless[arg] >> 32) : orig;
	case P_VP_XOFF: return fbits(d->viewport[0] + d->viewport[2] / 2);
	case P_VP_XSCALE: return fbits(d->viewport[2] / 2);
	case P_VP_YOFF: return fbits(d->viewport[1] + d->viewport[3] / 2);
	case P_VP_YSCALE: return fbits(d->viewport[3] / 2);
	case P_VPSC_TL:
	case P_SCSC_TL: {
		const uint32_t *s = p == P_VPSC_TL ? (uint32_t[]){ (uint32_t)d->viewport[0], (uint32_t)d->viewport[1] } : d->scissor;
		return (s[0] & 0x3fff) | (s[1] & 0x3fff) << 16;
	}
	case P_VPSC_BR: {
		uint32_t x = (uint32_t)(d->viewport[0] + d->viewport[2]), y = (uint32_t)(d->viewport[1] + d->viewport[3]);
		return ((x ? x - 1 : 0) & 0x3fff) | ((y ? y - 1 : 0) & 0x3fff) << 16;
	}
	case P_SCSC_BR: {
		uint32_t x = d->scissor[0] + d->scissor[2], y = d->scissor[1] + d->scissor[3];
		return ((x ? x - 1 : 0) & 0x3fff) | ((y ? y - 1 : 0) & 0x3fff) << 16;
	}
	case P_RT_PITCH: return t->pitch >> 6;		/* RB_MRT_PITCH/ARRAY_PITCH: 64-byte units */
	case P_RT_APITCH: return (t->pitch * t->height) >> 6;
	case P_RT_LO:
	case P_RT_FLAG_LO: return (uint32_t)t->va;
	case P_RT_HI:
	case P_RT_FLAG_HI: return (uint32_t)(t->va >> 32);
	case P_WINDOW_BR:
	case P_A2D_BR: return ((t->width - 1) & 0x3fff) | ((t->height - 1) & 0x3fff) << 16;
	/* colour format fields (RB_MRT_BUF_INFO: format 0-7, swap 13-14; SP_PS_MRT_REG: format, sRGB 10; LRZ: format) */
	case P_RT_INFO: return t->fmt6 ? (orig & ~0x60ffu) | (t->fmt6 & 0xff) | ((t->fmt6 >> 8) & 3) << 13 : orig;
	case P_RT_SPFMT: return t->fmt6 ? (orig & ~0x4ffu) | (t->fmt6 & 0xff) | ((t->fmt6 >> 10) & 1) << 10 : orig;
	case P_RT_LRZFMT: return t->fmt6 ? (orig & ~0xffu) | (t->fmt6 & 0xff) : orig;
	default: return orig;
	}
}

@interface SweetPipelineTemplate ()
@property (readonly) struct tgroup *groups;
@property (readonly) uint32_t ngroups;
@property (readonly) NSArray *prologue, *epilogue;
@property (readonly) uint32_t draw0;
@property (readonly) uint64_t shaderVA;
@end

@implementation SweetPipelineTemplate {
	struct sg_bo _shader, _static;
	struct tgroup _g[40];
	uint32_t _ng;
	NSArray *_pro, *_epi;
	uint32_t _draw0;
	NSDictionary *_res;
}

- (NSDictionary *)res { return _res; }

- (struct tgroup *)groups { return _g; }
- (uint32_t)ngroups { return _ng; }
- (NSArray *)prologue { return _pro; }
- (NSArray *)epilogue { return _epi; }
- (uint32_t)draw0 { return _draw0; }
- (uint64_t)shaderVA { return _shader.va; }

+ (instancetype)named:(NSString *)name
{
	static NSMutableDictionary *cache;
	if (!cache)
		cache = [NSMutableDictionary new];
	id t = cache[name];
	if (t)
		return t == [NSNull null] ? nil : t;
	NSString *dir = [[NSBundle bundleForClass:self].bundlePath stringByAppendingPathComponent:@"pipelines"];
	NSData *json = [NSData dataWithContentsOfFile:[dir stringByAppendingFormat:@"/%@.json", name]];
	SweetPipelineTemplate *tp = json ? [[self alloc] initWithJSON:json] : nil;
	cache[name] = tp ?: (id)[NSNull null];
	glog("template %s: %s", name.UTF8String, tp ? "loaded" : json ? "unusable" : "missing");
	return tp;
}

- (instancetype)initWithJSON:(NSData *)json
{
	SweetGPU *gpu = [SweetGPU shared];
	NSError *err = nil;
	NSDictionary *j = [NSJSONSerialization JSONObjectWithData:json options:0 error:&err];
	if (!j)
		glog("template: bad JSON (%s)", err.localizedDescription.UTF8String);
	if (!gpu || !j || !(self = [super init]))
		return nil;
	for (NSString *k in j[@"globals"])
		[gpu performSelector:@selector(setGlobals:) withObject:hexdata(j[@"globals"][k])];
	NSData *code = hexdata(j[@"shader"][@"data"]);
	if (![gpu alloc:code.length bo:&_shader]) {
		glog("template: no GPU memory for %lu bytes of shader code", (unsigned long)code.length);
		return nil;
	}
	memcpy(_shader.map, code.bytes, code.length);
	sg_cache_flush(gpu.dev, &_shader, 0, code.length);

	/* static groups (only shader/global patches) go into one buffer, built now */
	if (![gpu alloc:64 * 1024 bo:&_static])
		return nil;
	uint32_t used = 0;
	struct pctx c = { .shader_va = _shader.va, .globals_va = gpu.globalsVA };
	for (NSDictionary *g in j[@"groups"]) {
		struct tgroup *tg = &_g[_ng++];
		NSArray *dw = g[@"dw"], *patches = g[@"patch"];
		tg->ndw = (uint32_t)dw.count;
		tg->hdr = (uint32_t)dw.count | [g[@"flags"] unsignedIntValue] | [g[@"id"] unsignedIntValue] << 24;
		tg->dw = calloc(dw.count + 1, 4);
		for (NSUInteger i = 0; i < dw.count; i++)
			tg->dw[i] = [dw[i] unsignedIntValue];
		tg->patch = calloc(patches.count + 1, sizeof(*tg->patch));
		BOOL dynamic = NO;
		for (NSArray *p in patches) {
			uint32_t arg;
			enum pname pn = parse_patch(p[1], &arg);
			if (pn == P_SHADER_LO || pn == P_SHADER_HI || pn == P_GLOBAL_LO || pn == P_GLOBAL_HI) {
				uint32_t i = [p[0] unsignedIntValue];
				tg->dw[i] = patch_value(pn, arg, tg->dw[i], &c);
			} else if (pn != P_NONE) {
				tg->patch[tg->npatch][0] = [p[0] unsignedIntValue];
				tg->patch[tg->npatch][1] = (uint32_t)pn | arg << 8;
				tg->npatch++;
				dynamic = YES;
			}
		}
		if (!dynamic && tg->ndw) {
			memcpy((uint8_t *)_static.map + used, tg->dw, tg->ndw * 4);
			tg->va = _static.va + used;
			used += (tg->ndw * 4 + 31) & ~31u;
		}
	}
	sg_cache_flush(gpu.dev, &_static, 0, used);
	_res = j[@"res"];
	_pro = j[@"prologue"];
	_epi = j[@"epilogue"];
	_draw0 = [j[@"draw"][0] unsignedIntValue];
	return self;
}
@end

/* ---- command streams ---- */

@implementation SweetCmdStream {
	SweetGPU *_gpu;
	NSArray *_pair;
	struct sg_bo _ib, _sc;
	uint32_t _ndw, _scused;
	NSMutableArray *_touched;
	NSMutableSet *_kept;
	NSMutableArray *_after;		/* blocks to run once the GPU is done (afterGPU:) */
	struct sweet_target _target;
	BOOL _in_pass;
	unsigned _draws;
}

- (unsigned)draws { return _draws; }

- (instancetype)initWithGPU:(SweetGPU *)gpu
{
	if (!gpu || !(self = [super init]))
		return nil;
	_gpu = gpu;
	_pair = [gpu takeStream];
	if (!_pair)
		return nil;
	memcpy(&_ib, [_pair[0] bytes], sizeof(_ib));
	memcpy(&_sc, [_pair[1] bytes], sizeof(_sc));
	_touched = [NSMutableArray new];
	_kept = [NSMutableSet new];
	return self;
}

- (void)dealloc
{
	[_gpu giveStream:_pair];
}

- (void)put:(uint32_t)v
{
	if ((_ndw + 1) * 4 <= STREAM_BYTES)
		((uint32_t *)_ib.map)[_ndw++] = v;
}

- (uint64_t)scratch:(const void *)data length:(uint32_t)len
{
	uint32_t at = (_scused + 63) & ~63u;
	if (at + len > STREAM_BYTES)
		return 0;
	if (data)
		memcpy((uint8_t *)_sc.map + at, data, len);
	else
		memset((uint8_t *)_sc.map + at, 0, len);
	_scused = at + len;
	return _sc.va + at;
}

- (void)keep:(id)obj
{
	if (obj)
		[_kept addObject:obj];
}

- (void)touch:(const struct sg_bo *)bo
{
	for (NSData *b in _touched)
		if (((const struct sg_bo *)b.bytes)->va == bo->va)
			return;
	[_touched addObject:[NSData dataWithBytes:bo length:sizeof(*bo)]];
}

/* Template items: register writes (pkt4) and packets (pkt7), with patches. */
- (void)emitItems:(NSArray *)items ctx:(const struct pctx *)c
{
	for (NSDictionary *x in items) {
		if (x[@"r"]) {
			uint32_t v = [x[@"v"] unsignedIntValue];
			NSString *p = x[@"p"];
			if ([p isKindOfClass:[NSString class]]) {
				uint32_t arg;
				v = patch_value(parse_patch(p, &arg), arg, v, c);
			}
			[self put:sg_pkt4([x[@"r"] unsignedIntValue], 1)];
			[self put:v];
		} else {
			NSArray *b = x[@"b"];
			uint32_t body[64];
			uint32_t n = (uint32_t)MIN(b.count, 64u);
			for (uint32_t i = 0; i < n; i++)
				body[i] = [b[i] unsignedIntValue];
			for (NSArray *pb in x[@"pb"] ?: @[]) {
				uint32_t arg, i = [pb[0] unsignedIntValue];
				if (i < n)
					body[i] = patch_value(parse_patch(pb[1], &arg), arg, body[i], c);
			}
			[self put:sg_pkt7([x[@"k"] unsignedIntValue], n)];
			for (uint32_t i = 0; i < n; i++)
				[self put:body[i]];
		}
	}
}

static SweetPipelineTemplate *pass_template;	/* the prologue/epilogue come from any template */

- (BOOL)beginPass:(const struct sweet_target *)t
{
	if (!pass_template) {
		pass_template = [SweetPipelineTemplate named:@"pass"];
		if (!pass_template)
			return NO;
	}
	_target = *t;
	struct pctx c = { .globals_va = _gpu.globalsVA, .t = &_target };
	[self emitItems:pass_template.prologue ctx:&c];
	_in_pass = YES;
	return YES;
}

- (void)draw:(const struct sweet_draw *)d template:(SweetPipelineTemplate *)tp
{
	if (!_in_pass || !tp)
		return;
	/* descriptor sets 0 (vertex buffers) and 1 (fragment buffers): UBO descriptors in 64-byte slots */
	uint32_t sets[2][8 * 16];
	memset(sets, 0, sizeof(sets));
	for (int s = 0; s < 2; s++)
		for (int b = 0; b < 8; b++) {
			uint64_t va = s ? d->fubo_va[b] : d->vubo_va[b];
			uint32_t size = s ? d->fubo_size[b] : d->vubo_size[b];
			if (!va)
				continue;
			sets[s][b * 16 + 0] = (uint32_t)va;
			sets[s][b * 16 + 1] = (uint32_t)(va >> 32) | ((size + 15) / 16) << 17;
		}
	struct pctx c = { .shader_va = tp.shaderVA, .globals_va = _gpu.globalsVA, .t = &_target, .d = d };
	c.bindless[0] = [self scratch:sets[0] length:sizeof(sets[0])];
	c.bindless[1] = [self scratch:sets[1] length:sizeof(sets[1])];
	/* sets 2 (textures) and 3 (samplers): 64-byte slots, as turnip lays them out */
	if (d->tex_mask || d->smp_mask) {
		static uint32_t ts[16 * 16], ss[24 * 16];
		memset(ts, 0, sizeof(ts));
		memset(ss, 0, sizeof(ss));
		for (int i = 0; i < 16; i++)
			if (d->tex_mask & (1u << i))
				memcpy(&ts[i * 16], d->tex[i], 64);
		for (int i = 0; i < 24; i++)
			if (d->smp_mask & (1u << i))
				memcpy(&ss[i * 16], d->smp[i], 16);
		c.bindless[2] = [self scratch:ts length:sizeof(ts)];
		c.bindless[3] = [self scratch:ss length:sizeof(ss)];
	}

	/* the draw's state: static groups as built, dynamic ones patched into scratch */
	struct tgroup *g = tp.groups;
	uint32_t n = tp.ngroups;
	uint64_t va[40];
	for (uint32_t i = 0; i < n; i++) {
		if (!g[i].npatch) {
			va[i] = g[i].va;
			continue;
		}
		uint32_t dw[256];
		uint32_t nd = MIN(g[i].ndw, 256u);
		memcpy(dw, g[i].dw, nd * 4);
		for (uint32_t k = 0; k < g[i].npatch; k++) {
			uint32_t at = g[i].patch[k][0], pn = g[i].patch[k][1];
			if (at < nd)
				dw[at] = patch_value((enum pname)(pn & 0xff), pn >> 8, dw[at], &c);
		}
		va[i] = [self scratch:dw length:nd * 4];
	}
	if (d->fbfetch || d->dest_va) {
		/* earlier draws' colour writes out of the CCU, texture caches invalidated (turnip, sysmem input attachments) */
		uint64_t ts = _gpu.globalsVA + 0x4000;
		[self put:sg_pkt7(0x46, 4)];		/* CP_EVENT_WRITE PC_CCU_FLUSH_COLOR_TS */
		[self put:0x1d];
		[self put:(uint32_t)ts];
		[self put:(uint32_t)(ts >> 32)];
		[self put:0];
		[self put:sg_pkt7(0x46, 1)];		/* CP_EVENT_WRITE CACHE_INVALIDATE */
		[self put:0x31];
		[self put:sg_pkt7(0x26, 0)];		/* CP_WAIT_FOR_IDLE */
	}
	if (d->dest_va) {				/* RB_MRT[0].BASE -> the memoryless attachment's buffer */
		[self put:sg_pkt4(0x8825, 2)];
		[self put:(uint32_t)d->dest_va];
		[self put:(uint32_t)(d->dest_va >> 32)];
	}
	[self put:sg_pkt7(CP_SET_DRAW_STATE, 3 * n)];
	for (uint32_t i = 0; i < n; i++) {
		[self put:g[i].hdr];
		[self put:(uint32_t)va[i]];
		[self put:(uint32_t)(va[i] >> 32)];
	}
	/*
	 * CP_DRAW_INDX_OFFSET_0 as captured (triangle list, indexed): PRIM_TYPE bits 0-5, SOURCE_SELECT 6-7
	 * (0 DMA = index buffer, 2 AUTO_INDEX), INDEX_SIZE 10-11 (1 = 16-bit, 2 = 32-bit)
	 */
	uint32_t d0 = tp.draw0;
	if (d->prim)
		d0 = (d0 & ~0x3fu) | d->prim;
	if (d->ib_va) {
		if (d->index_u32)
			d0 = (d0 & ~(3u << 10)) | 2u << 10;
		[self put:sg_pkt7(CP_DRAW_INDX_OFFSET, 7)];
		[self put:d0];
		[self put:d->instances ?: 1];
		[self put:d->index_count];
		[self put:0];
		[self put:(uint32_t)d->ib_va];
		[self put:(uint32_t)(d->ib_va >> 32)];
		[self put:d->index_count];
	} else {
		d0 = (d0 & ~(3u << 6 | 3u << 10)) | 2u << 6;
		[self put:sg_pkt7(CP_DRAW_INDX_OFFSET, 3)];
		[self put:d0];
		[self put:d->instances ?: 1];
		[self put:d->index_count];
	}
	if (d->dest_va) {				/* back to the pass's colour target */
		uint64_t ts = _gpu.globalsVA + 0x4000;
		[self put:sg_pkt7(0x46, 4)];
		[self put:0x1d];
		[self put:(uint32_t)ts];
		[self put:(uint32_t)(ts >> 32)];
		[self put:0];
		[self put:sg_pkt7(0x26, 0)];
		[self put:sg_pkt4(0x8825, 2)];
		[self put:(uint32_t)_target.va];
		[self put:(uint32_t)(_target.va >> 32)];
	}
	_draws++;
}

- (void)endPass
{
	if (!_in_pass)
		return;
	struct pctx c = { .globals_va = _gpu.globalsVA, .t = &_target };
	[self emitItems:pass_template.epilogue ctx:&c];
	if (getenv("SWEET_PASS_FLUSH") || access("/var/local/mtl-passflush", F_OK) == 0) {
		/* experiment: the pass's colour all the way to memory before anything reads it */
		uint64_t ts = _gpu.globalsVA + 0x4000;
		[self put:sg_pkt7(0x46, 4)];		/* CP_EVENT_WRITE CACHE_FLUSH_TS */
		[self put:0x04];
		[self put:(uint32_t)ts];
		[self put:(uint32_t)(ts >> 32)];
		[self put:0];
		[self put:sg_pkt7(0x46, 1)];		/* CP_EVENT_WRITE CACHE_INVALIDATE */
		[self put:0x31];
		[self put:sg_pkt7(0x26, 0)];		/* CP_WAIT_FOR_IDLE */
	}
	_in_pass = NO;
}

double sweet_stat_flush_ms, sweet_stat_gpu_ms;
uint64_t sweet_stat_flush_bytes;

static double now_ms(void)
{
	return [NSDate timeIntervalSinceReferenceDate] * 1000.0;
}

- (int)submit
{
	if (!_ndw || !_draws)
		return 0;
	struct sg_dev *dev = _gpu.dev;
	double t0 = now_ms();
	sg_cache_flush(dev, &_ib, 0, _ndw * 4);
	sg_cache_flush(dev, &_sc, 0, _scused);
	for (NSData *b in _touched) {
		const struct sg_bo *bo = b.bytes;
		sg_cache_flush(dev, bo, 0, bo->size);
		sweet_stat_flush_bytes += bo->size;
	}
	double t1 = now_ms();
	uint32_t fence = 0;
	int r = sg_submit(dev, _ib.va, _ndw, 1000, &fence);
	if (r)
		sweet_free_log_dump();
	sweet_stat_flush_ms += t1 - t0;
	sweet_stat_gpu_ms += now_ms() - t1;
	static int logged;
	if (logged++ < 5 || r)
		glog("submit %u dwords, %u draws -> %d", _ndw, _draws, r);
	_ndw = _scused = 0;
	_draws = 0;
	[_touched removeAllObjects];
	for (dispatch_block_t b in _after)
		b();
	[_after removeAllObjects];
	[_kept removeAllObjects];
	[_gpu sweepSurfaces];
	return r;
}

- (uint32_t)submitAsync
{
	if (!_ndw || !_draws)
		return 0;
	struct sg_dev *dev = _gpu.dev;
	double t0 = now_ms();
	sg_cache_flush(dev, &_ib, 0, _ndw * 4);
	sg_cache_flush(dev, &_sc, 0, _scused);
	for (NSData *b in _touched) {
		const struct sg_bo *bo = b.bytes;
		sg_cache_flush(dev, bo, 0, bo->size);
		sweet_stat_flush_bytes += bo->size;
	}
	sweet_stat_flush_ms += now_ms() - t0;
	uint32_t fence = 0;
	if (sg_submit_async(dev, _ib.va, _ndw, &fence)) {
		glog("async submit of %u dwords failed", _ndw);
		fence = 0;
	}
	_ndw = _scused = 0;
	_draws = 0;
	[_touched removeAllObjects];
	return fence;
}

- (void)copyGPU:(uint64_t)src to:(uint64_t)dst bytes:(uint32_t)len
{
	/* colour writes out of the CCU, then the UCHE to memory: CP_MEMCPY reads memory */
	uint64_t ts = _gpu.globalsVA + 0x4000;
	[self put:sg_pkt7(0x46, 4)];		/* CP_EVENT_WRITE PC_CCU_FLUSH_COLOR_TS */
	[self put:0x1d];
	[self put:(uint32_t)ts];
	[self put:(uint32_t)(ts >> 32)];
	[self put:0];
	[self put:sg_pkt7(0x46, 4)];		/* CP_EVENT_WRITE CACHE_FLUSH_TS */
	[self put:0x04];
	[self put:(uint32_t)ts];
	[self put:(uint32_t)(ts >> 32)];
	[self put:0];
	[self put:sg_pkt7(0x26, 0)];		/* CP_WAIT_FOR_IDLE */
	for (uint32_t o = 0; o < len; o += 1u << 20) {	/* CP_MEMCPY in 1 MB pieces */
		uint32_t n = MIN(len - o, 1u << 20);
		[self put:sg_pkt7(0x75, 5)];		/* CP_MEMCPY: dwords, src, dst */
		[self put:n / 4];
		[self put:(uint32_t)(src + o)];
		[self put:(uint32_t)((src + o) >> 32)];
		[self put:(uint32_t)(dst + o)];
		[self put:(uint32_t)((dst + o) >> 32)];
	}
	[self put:sg_pkt7(0x26, 0)];
}

- (void)afterGPU:(dispatch_block_t)b
{
	if (!_after)
		_after = [NSMutableArray new];
	[_after addObject:[b copy]];
}

- (void)retire:(uint32_t)fence
{
	if (fence) {
		double t0 = now_ms();
		if (sg_wait_fence(_gpu.dev, fence, 1000)) {
			glog("fence %u: timeout or fault", fence);
			sweet_free_log_dump();
		}
		sweet_stat_gpu_ms += now_ms() - t0;
	}
	for (dispatch_block_t b in _after)
		b();
	[_after removeAllObjects];
	[_kept removeAllObjects];
	[_gpu sweepSurfaces];
}
@end
