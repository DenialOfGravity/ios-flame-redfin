/*
 * SweetMetal.bundle: the Metal driver for the Adreno 640, loaded by
 * Metal.framework for the kernel's SweetAccelerator (IOAcceleratorES with
 * MetalPluginName = SweetMetal; iokit/Kernel/arm/SweetAccelerator.cpp).
 *
 * Built up by discovery: every class (device, queue, command buffer, ...)
 * routes the Metal base class's and protocols' selectors it does not
 * implement through a logger that records their first use (to /dev/console:
 * "MTL[pid name]: Class -selector (base | MISSING)") and then runs the base
 * class (or returns zero). That shows which Metal API Core Animation needs.
 * Stage 2: a command queue whose buffers complete at once.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import "a6draw.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <unistd.h>

@interface _MTLDevice : NSObject
@end

@interface NSInvocation (Private)
- (void)invokeUsingIMP:(IMP)imp;
@end

@interface SweetMTLDevice : _MTLDevice
@end

static int log_fd = -2;

/*
 * Metal validation failures (MTLReportFailure) abort by default. Frameworks with kernels only for Apple
 * GPUs (MetalPerformanceShaders: "device is not supported ... Returning nil") report one on our device,
 * which killed SpringBoard (Siri orb). Log them instead; the callers already cope with the nil.
 */
__attribute__((constructor)) static void sweet_error_mode(void)
{
	/* Metal read METAL_ERROR_MODE before we load: set the cached modes (types 0..4; 5 = nslog). */
	void (*set)(unsigned, unsigned) = dlsym(RTLD_DEFAULT, "MTLFailureTypeSetErrorModeType");
	for (unsigned t = 0; set && t < 5; t++)
		set(t, 5);
}

static void mlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void mlog(const char *fmt, ...)
{
	char buf[600];
	int n = snprintf(buf, sizeof(buf), "MTL[%d %s]: ", getpid(), getprogname());
	va_list ap;
	va_start(ap, fmt);
	n += vsnprintf(buf + n, sizeof(buf) - (size_t)n - 1, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof(buf) - 2)
		n = (int)sizeof(buf) - 2;
	buf[n++] = '\n';
	if (log_fd == -2)
		log_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (log_fd >= 0)
		write(log_fd, buf, (size_t)n);
	/* the live (UDP) log drops lines in bursts: a file copy too, when /var/local/mtl.log exists (mode 666) */
	static int file_fd = -2;
	if (file_fd == -2)
		file_fd = open("/var/local/mtl.log", O_WRONLY | O_APPEND);
	if (file_fd >= 0)
		write(file_fd, buf, (size_t)n);
}

/* Pipeline keys also go to /var/local/mtl-keys.log (append-only, never truncated: the host's template list) */
static void klog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void klog(const char *fmt, ...)
{
	char buf[600];
	int n = snprintf(buf, sizeof(buf), "MTL[%d %s]: ", getpid(), getprogname());
	va_list ap;
	va_start(ap, fmt);
	n += vsnprintf(buf + n, sizeof(buf) - (size_t)n - 1, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof(buf) - 2)
		n = (int)sizeof(buf) - 2;
	buf[n] = 0;
	mlog("%s", strchr(buf, ':') + 2);	/* (mlog adds its own prefix) */
	buf[n++] = '\n';
	static int fd = -2;
	if (fd == -2)
		fd = open("/var/local/mtl-keys.log", O_WRONLY | O_APPEND);
	if (fd >= 0)
		write(fd, buf, (size_t)n);
}

/* Selectors that must keep their normal implementations. */
static BOOL keep(SEL s)
{
	static const char *const names[] = {
		"init", "dealloc", "retain", "release", "autorelease", "retainCount", "class", "superclass",
		"isKindOfClass:", "isMemberOfClass:", "respondsToSelector:", "conformsToProtocol:",
		"methodSignatureForSelector:", "forwardInvocation:", "forwardingTargetForSelector:", "hash",
		"isEqual:", "self", "zone", "_tryRetain", "_isDeallocating", "allowsWeakReference",
		"retainWeakReference", ".cxx_destruct", ".cxx_construct", "initWithAcceleratorPort:",
		"description", "debugDescription", "name",
	};
	const char *n = sel_getName(s);
	for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++)
		if (!strcmp(n, names[i]))
			return YES;
	return NO;
}

/*
 * The logging forwarder, for every driver class: selectors of the Metal base
 * class and of the protocols the class must conform to, that the class does
 * not implement itself, go to forwardInvocation:, which logs their first use
 * and runs the base class's implementation (or returns zero).
 */
static NSMutableDictionary *types;	/* "Class -selector" -> type encoding */
static NSMutableSet *seen;

static void route(Class cls, SEL s, const char *t)
{
	NSString *k = [NSString stringWithFormat:@"%s %s", class_getName(cls), sel_getName(s)];
	if (!s || !t || keep(s) || types[k])
		return;
	types[k] = [NSString stringWithUTF8String:t];
	/* our own implementations (on cls itself) stay */
	unsigned n = 0;
	Method *own = class_copyMethodList(cls, &n);
	BOOL mine = NO;
	for (unsigned i = 0; i < n; i++)
		if (method_getName(own[i]) == s)
			mine = YES;
	free(own);
	if (!mine)
		class_addMethod(cls, s, _objc_msgForward, t);
}

static void route_protocol(Class cls, Protocol *p)
{
	for (int req = 0; req < 2; req++) {
		unsigned n = 0;
		struct objc_method_description *m = protocol_copyMethodDescriptionList(p, req, YES, &n);
		for (unsigned i = 0; i < n; i++)
			route(cls, m[i].name, m[i].types);
		free(m);
	}
	unsigned np = 0;
	Protocol *__unsafe_unretained *sub = protocol_copyProtocolList(p, &np);
	for (unsigned i = 0; i < np; i++)
		if (strcmp(protocol_getName(sub[i]), "NSObject"))
			route_protocol(cls, sub[i]);
	free(sub);
}

/* Route cls's base class methods and these protocols ("MTLDevice", ...) through the logger. */
static void route_class(Class cls, const char *base, const char *const *protocols)
{
	if (!types) {
		types = [NSMutableDictionary new];
		seen = [NSMutableSet new];
	}
	unsigned n = 0;
	Method *m = base ? class_copyMethodList(objc_getClass(base), &n) : NULL;	/* NULL: protocols only */
	for (unsigned i = 0; i < n; i++)
		route(cls, method_getName(m[i]), method_getTypeEncoding(m[i]));
	free(m);
	for (; protocols && *protocols; protocols++) {
		Protocol *p = objc_getProtocol(*protocols);
		if (!p)
			continue;
		class_addProtocol(cls, p);
		route_protocol(cls, p);
	}
}

static NSMethodSignature *routed_signature(id self, SEL sel)
{
	NSString *t = types[[NSString stringWithFormat:@"%s %s", object_getClassName(self), sel_getName(sel)]];
	return t ? [NSMethodSignature signatureWithObjCTypes:t.UTF8String] : nil;
}

/* Log the first use, then run the base class (or return zero). */
static void routed_invoke(id self, NSInvocation *inv, const char *base)
{
	SEL sel = inv.selector;
	NSString *k = [NSString stringWithFormat:@"%s %s", object_getClassName(self), sel_getName(sel)];
	IMP sup = base ? class_getMethodImplementation(objc_getClass(base), sel) : NULL;
	BOOL has = sup && sup != _objc_msgForward;
	if (![seen containsObject:k]) {
		[seen addObject:k];
		mlog("%s -%s (%s)", object_getClassName(self), sel_getName(sel), has ? base : "MISSING: returns 0");
		if (!has && strstr(sel_getName(sel), "new") == sel_getName(sel))
			mlog("  ^ nil from a -new... method: likely the next crash");
	}
	if (has) {
		[inv invokeUsingIMP:sup];
		return;
	}
	NSUInteger len = inv.methodSignature.methodReturnLength;
	if (len) {
		void *z = calloc(1, len);
		[inv setReturnValue:z];
		free(z);
	}
}

/* methodSignatureForSelector: + forwardInvocation: for a routed class */
#define ROUTED(BASE)                                                                  \
	-(NSMethodSignature *)methodSignatureForSelector : (SEL)sel                   \
	{                                                                             \
		NSMethodSignature *s = routed_signature(self, sel);                   \
		if (!s)                                                               \
			s = [super methodSignatureForSelector:sel];                   \
		if (!s) {                                                             \
			mlog("%s -%s: no signature", object_getClassName(self), sel_getName(sel)); \
			s = [NSMethodSignature signatureWithObjCTypes:"@@:"];         \
		}                                                                     \
		return s;                                                             \
	}                                                                             \
	-(void)forwardInvocation : (NSInvocation *)inv                                \
	{                                                                             \
		routed_invoke(self, inv, BASE);                                       \
	}

@interface _MTLCommandQueue : NSObject
- (id)initWithDevice:(id)device;
- (void)completeCommandBuffers:(const id *)buffers count:(unsigned long long)count;
@end
@interface _MTLCommandBuffer : NSObject
- (id)initWithQueue:(id)queue retainedReferences:(BOOL)retained;
- (void)didScheduleWithStartTime:(unsigned long long)start endTime:(unsigned long long)end error:(id)error;
@end


/* ---- Objects, stage 3: they record state; nothing is drawn yet ---- */

@interface _MTLCommandEncoder : NSObject
- (id)initWithCommandBuffer:(id)cb;
- (void)endEncoding;
@end

static NSUInteger sweet_bpp(MTLPixelFormat f)
{
	switch ((NSUInteger)f) {
	case 10: case 11: case 13: case 1: return 1;			/* R8*, A8 */
	case 20: case 30: case 25: case 40: case 41: case 42: case 43: return 2;	/* R16*, RG8, 16-bit packed */
	case 115: case 113: case 105: return 8;				/* RGBA16Float/Unorm, RG32 */
	case 125: return 16;						/* RGBA32Float */
	default: return 4;						/* BGRA8, RGBA8, RGB10A2, BGR10A2, R32 ... */
	}
}

/* A6XX texture format for a Metal pixel format: FMT6 | swap << 8 | srgb << 10 | (R8 as A8) << 11; 0 = none */
static uint32_t sweet_fmt6(NSUInteger f)
{
	switch (f) {
	case 1: return 0x03 | 1u << 11;		/* A8Unorm: R8 with swizzle 0,0,0,X */
	case 10: return 0x03;			/* R8Unorm */
	case 30: return 0x0f;			/* RG8Unorm */
	case 70: return 0x30;			/* RGBA8Unorm */
	case 71: return 0x30 | 1u << 10;	/* RGBA8Unorm_sRGB */
	case 80: return 0x30 | 1u << 8;		/* BGRA8Unorm: swap WXYZ */
	case 81: return 0x30 | 1u << 8 | 1u << 10;
	case 25: return 0x17;			/* R16Float */
	case 65: return 0x45;			/* RG16Float */
	case 115: return 0x62;			/* RGBA16Float */
	case 55: return 0x4a;			/* R32Float */
	case 40: return 0x0e | 1u << 8;		/* B5G6R5Unorm (VK R5G6B5: swap WXYZ) */
	case 43: return 0x0a | 1u << 8;		/* BGR5A1Unorm (VK A1R5G5B5 = B5G5R5A1: 5_5_5_1, WXYZ) */
	case 90: return 0x36;			/* RGB10A2Unorm */
	case 94: return 0x36 | 1u << 8;		/* BGR10A2Unorm */
	default: return 0;
	}
}

/* Buffers (implementation below; textures can live in one) */
@interface SweetMTLBuffer : NSObject
- (const struct sg_bo *)bo;
- (void)sweetSync;
- (uint64_t)gpuAddress;
- (void *)contents;
@property (weak) id device;
@property (copy) NSString *label;
@property NSUInteger length;
@property MTLResourceOptions resourceOptions;
@end

/* /var/local/mtl-trace present when the process starts: log what happens to textures of 512+ pixels */
static BOOL sweet_trace(void)
{
	static int on = -1;
	if (on < 0)
		on = access("/var/local/mtl-trace", F_OK) == 0;
	return on;
}
#define TRACE_TEX(t) (sweet_trace() && ((t).width >= 512 || (t).height >= 512))

/* Textures: GPU memory (or an IOSurface's pixels); CPU memory only without a GPU. */
@interface SweetMTLTexture : NSObject
@property (weak) id device;
@property (copy) NSString *label;
@property MTLTextureType textureType;
@property MTLPixelFormat pixelFormat;
@property NSUInteger width, height, depth, mipmapLevelCount, sampleCount, arrayLength;
@property MTLTextureUsage usage;
@property MTLStorageMode storageMode;
@property MTLCPUCacheMode cpuCacheMode;
@property NSUInteger bytesPerRow;
@property IOSurfaceRef iosurface;
@property NSUInteger iosurfacePlane;
- (uint64_t)sweetVA;
- (NSUInteger)sweetPitch;
- (BOOL)sweetNeedsClean;
- (void)sweetMarkCPUWrite;
- (const struct sg_bo *)sweetBO;
@end

@implementation SweetMTLTexture {
	uint8_t *_mem;
	BOOL _own;
	struct sg_bo _bo;	/* GPU memory (map = _mem) when there is a GPU and no IOSurface */
	BOOL _gpu;
	struct sg_bo _shadow;	/* IOSurface with a pitch the GPU cannot sample: an aligned copy */
	uint32_t _shadowSeed, _shadowPitch;
	BOOL _haveShadow;
	BOOL _cpuDirty;		/* CPU wrote the pixels since the last cache clean */
	uint32_t _flushedSeed;	/* IOSurface seed at the last cache clean (+1; 0 = never) */
	id _buffer;		/* buffer-backed (newLinearTextureWithDescriptor:...): its SweetMTLBuffer */
	NSUInteger _bufOffset;
}
+ (void)initialize
{
	if (self == [SweetMTLTexture class]) {
		static const char *const pr[] = { "MTLTexture", "MTLTextureSPI", "MTLTextureImplementation", NULL };
		route_class(self, NULL, pr);
	}
}
ROUTED(NULL)

- (instancetype)initWithDevice:(id)dev descriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)ios plane:(NSUInteger)plane
{
	if (!(self = [super init]))
		return nil;
	_device = dev;
	_textureType = d.textureType;
	_pixelFormat = d.pixelFormat;
	_width = d.width;
	_height = d.height;
	_depth = d.depth ?: 1;
	_mipmapLevelCount = d.mipmapLevelCount ?: 1;
	_sampleCount = d.sampleCount ?: 1;
	_arrayLength = d.arrayLength ?: 1;
	_usage = d.usage;
	_storageMode = d.storageMode;
	_cpuCacheMode = d.cpuCacheMode;
	if (ios) {
		_iosurface = (IOSurfaceRef)CFRetain(ios);
		_iosurfacePlane = plane;
		_bytesPerRow = IOSurfaceGetPlaneCount(ios) ? IOSurfaceGetBytesPerRowOfPlane(ios, plane) : IOSurfaceGetBytesPerRow(ios);
		_mem = IOSurfaceGetPlaneCount(ios) ? IOSurfaceGetBaseAddressOfPlane(ios, plane) : IOSurfaceGetBaseAddress(ios);
	} else {
		_bytesPerRow = (_width * sweet_bpp(_pixelFormat) + 63) & ~(NSUInteger)63;
		NSUInteger size = _bytesPerRow * _height * _depth * _arrayLength + 64;
		SweetGPU *g = [SweetGPU shared];
		if (g && [g alloc:(size + 4095) & ~(NSUInteger)4095 bo:&_bo]) {
			_gpu = YES;
			_mem = _bo.map;
		} else {
			_mem = calloc(1, size);
			_own = YES;
		}
	}
	if (TRACE_TEX(self))
		mlog("trace: new texture %p %lux%lu fmt %lu usage %lx storage %lu%s va %llx", self, (unsigned long)_width,
		     (unsigned long)_height, (unsigned long)_pixelFormat, (unsigned long)_usage, (unsigned long)_storageMode,
		     ios ? " iosurface" : "", [self sweetVA]);
	return self;
}

/*
 * The A640 samples linear textures with 64-byte aligned pitches only. An IOSurface with another pitch is
 * copied (rows) into a shadow buffer whenever its seed changes. Returns the pitch to sample with.
 */
- (BOOL)sweetUnaligned
{
	if (_buffer)
		return (_bytesPerRow & 63) || (([(SweetMTLBuffer *)_buffer gpuAddress] + _bufOffset) & 63);
	return _iosurface && (_bytesPerRow & 63);
}

- (NSUInteger)sweetPitch
{
	if (![self sweetUnaligned])
		return _bytesPerRow;
	NSUInteger rowb = _width * sweet_bpp(_pixelFormat), pitch = (rowb + 63) & ~(NSUInteger)63;
	if (!_haveShadow) {
		SweetGPU *g = [SweetGPU shared];
		if (!g || ![g alloc:(pitch * _height + 4095) & ~(NSUInteger)4095 bo:&_shadow])
			return _bytesPerRow;
		_haveShadow = YES;
		_shadowSeed = ~IOSurfaceGetSeed(_iosurface);
		_shadowPitch = (uint32_t)pitch;
	}
	/* IOSurface: copy when its seed moved; buffer: every use (the CPU writes it without telling us) */
	uint32_t seed = _iosurface ? IOSurfaceGetSeed(_iosurface) : _shadowSeed + 1;
	if (seed != _shadowSeed) {
		for (NSUInteger y = 0; y < _height; y++)
			memcpy((uint8_t *)_shadow.map + y * pitch, _mem + y * _bytesPerRow, MIN(rowb, _bytesPerRow));
		_shadowSeed = seed;
	}
	return pitch;
}

/* GPU address and memory of the pixels (level 0); NULL bo for an IOSurface (the caller imports it) */
- (uint64_t)sweetVA
{
	if (_gpu)
		return _bo.va;
	if ([self sweetUnaligned])
		return [self sweetPitch] != _bytesPerRow || _haveShadow ? _shadow.va : 0;
	if (_buffer) {
		[(SweetMTLBuffer *)_buffer sweetSync];
		return [(SweetMTLBuffer *)_buffer gpuAddress] + _bufOffset;
	}
	if (!_iosurface)
		return 0;
	uint64_t va = [[SweetGPU shared] vaForSurface:_iosurface];
	if (va && IOSurfaceGetPlaneCount(_iosurface))
		va += (uint64_t)((uint8_t *)IOSurfaceGetBaseAddressOfPlane(_iosurface, _iosurfacePlane) -
				 (uint8_t *)IOSurfaceGetBaseAddress(_iosurface));
	return va;
}
/* Does the GPU need a cache clean of these pixels before it reads them? (CPU writes since the last one) */
- (BOOL)sweetNeedsClean
{
	if (_buffer && !_haveShadow)
		return YES;		/* buffer memory: the CPU may have written it any time */
	if (_iosurface && !_haveShadow) {
		uint32_t seed = IOSurfaceGetSeed(_iosurface) + 1;
		if (seed == _flushedSeed)
			return NO;
		_flushedSeed = seed;
		return YES;
	}
	if (_haveShadow) {
		uint32_t seed = _shadowSeed + 1;	/* refreshed by sweetPitch when the seed moved */
		if (seed == _flushedSeed)
			return NO;
		_flushedSeed = seed;
		return YES;
	}
	BOOL d = _cpuDirty;
	_cpuDirty = NO;
	return d;
}
- (void)sweetMarkCPUWrite
{
	_cpuDirty = YES;
	_flushedSeed = 0;
}

- (const struct sg_bo *)sweetBO
{
	if (_gpu)
		return &_bo;
	if (_haveShadow)
		return &_shadow;
	if (_buffer)
		return [(SweetMTLBuffer *)_buffer bo];
	return _iosurface ? [[SweetGPU shared] boForSurface:_iosurface] : NULL;
}

/* A texture over a buffer's memory (linear, the given pitch) */
- (instancetype)initWithDevice:(id)dev descriptor:(MTLTextureDescriptor *)d buffer:(id)buf offset:(NSUInteger)off
		   bytesPerRow:(NSUInteger)bpr
{
	if (!(self = [super init]))
		return nil;
	_device = dev;
	_textureType = d.textureType;
	_pixelFormat = d.pixelFormat;
	_width = d.width;
	_height = d.height;
	_depth = d.depth ?: 1;
	_mipmapLevelCount = 1;
	_sampleCount = 1;
	_arrayLength = 1;
	_usage = d.usage;
	_storageMode = d.storageMode;
	_cpuCacheMode = d.cpuCacheMode;
	_buffer = buf;
	_bufOffset = off;
	_bytesPerRow = bpr;
	_mem = (uint8_t *)[buf contents] + off;
	_cpuDirty = YES;
	return self;
}

- (id)buffer { return _buffer; }
- (NSUInteger)bufferOffset { return _bufOffset; }
- (NSUInteger)bufferBytesPerRow { return _buffer ? _bytesPerRow : 0; }

- (void)dealloc
{
	if (_gpu)
		sg_bo_free([SweetGPU shared].dev, &_bo);
	if (_haveShadow)
		sg_bo_free([SweetGPU shared].dev, &_shadow);
	if (_own)
		free(_mem);
	if (_iosurface)
		CFRelease(_iosurface);
}

- (uint8_t *)sweetBytes { return _mem; }
- (NSUInteger)allocatedSize { return _bytesPerRow * _height; }
- (BOOL)isFramebufferOnly { return NO; }
- (id)parentTexture { return nil; }
- (id)rootResource { return nil; }
- (MTLResourceOptions)resourceOptions { return (MTLResourceOptions)_storageMode << MTLResourceStorageModeShift; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }

- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)src
	  bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi
{
	if (level || !_mem)
		return;
	if (TRACE_TEX(self))
		mlog("trace: replaceRegion %p %lu,%lu %lux%lu", self, (unsigned long)r.origin.x, (unsigned long)r.origin.y,
		     (unsigned long)r.size.width, (unsigned long)r.size.height);
	[self sweetMarkCPUWrite];
	NSUInteger px = sweet_bpp(_pixelFormat);
	for (NSUInteger y = 0; y < r.size.height && r.origin.y + y < _height; y++)
		memcpy(_mem + (r.origin.y + y) * _bytesPerRow + r.origin.x * px, (const uint8_t *)src + y * bpr,
		       MIN(r.size.width, _width - r.origin.x) * px);
}

- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level withBytes:(const void *)src bytesPerRow:(NSUInteger)bpr
{
	[self replaceRegion:r mipmapLevel:level slice:0 withBytes:src bytesPerRow:bpr bytesPerImage:0];
}

- (void)getBytes:(void *)dst bytesPerRow:(NSUInteger)bpr bytesPerImage:(NSUInteger)bpi fromRegion:(MTLRegion)r
     mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
	if (!slice)
		[self getBytes:dst bytesPerRow:bpr fromRegion:r mipmapLevel:level];
}

- (void)getBytes:(void *)dst bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level
{
	if (level || !_mem)
		return;
	/* the GPU may have drawn it: drop stale CPU cache lines first */
	const struct sg_bo *bo = [self sweetBO];
	if (bo && !_haveShadow)
		sg_cache_flush([SweetGPU shared].dev, bo, 0, bo->size);
	if (TRACE_TEX(self))
		mlog("trace: getBytes %p %lux%lu", self, (unsigned long)r.size.width, (unsigned long)r.size.height);
	NSUInteger px = sweet_bpp(_pixelFormat);
	for (NSUInteger y = 0; y < r.size.height && r.origin.y + y < _height; y++)
		memcpy((uint8_t *)dst + y * bpr, _mem + (r.origin.y + y) * _bytesPerRow + r.origin.x * px,
		       MIN(r.size.width, _width - r.origin.x) * px);
}
@end

/* The A6XX texture descriptor (16 dwords, A6XX_TEX_MEMOBJ) of level 0 of a texture; NO if not drawable. */
static BOOL sweet_tex_desc(SweetMTLTexture *t, uint32_t d[16])
{
	uint32_t f = sweet_fmt6(t.pixelFormat);
	uint64_t va = f ? [t sweetVA] : 0;
	NSUInteger pitch = [t sweetPitch];
	if (!va || (va & 31) || (pitch & 63))
		return NO;
	memset(d, 0, 64);
	uint32_t swiz = (f & 1u << 11) ? (4u | 4u << 3 | 4u << 6 | 0u << 9) : (0u | 1u << 3 | 2u << 6 | 3u << 9);
	BOOL three = t.textureType == MTLTextureType3D;
	d[0] = (f & 1u << 10 ? 1u << 2 : 0) | swiz << 4 | (f & 0xff) << 22 | ((f >> 8) & 3) << 30;
	d[1] = ((uint32_t)t.width & 0x7fff) | ((uint32_t)t.height & 0x7fff) << 15;
	d[2] = (uint32_t)pitch << 7 | (three ? 3u : 1u) << 29;	/* PITCHALIGN 0: 64 bytes */
	d[3] = (uint32_t)((pitch * t.height) >> 12);
	d[4] = (uint32_t)va;
	d[5] = (uint32_t)(va >> 32) | (uint32_t)(three ? t.depth : 1) << 17;
	return YES;
}

/* The A6XX sampler descriptor (4 dwords, A6XX_TEX_SAMP) for a Metal sampler descriptor; nil = linear, clamp. */
static void sweet_smp_desc(MTLSamplerDescriptor *s, uint32_t d[4])
{
	static const uint32_t wrap[] = { 1, 4, 0, 2, 3, 3 };	/* ClampToEdge, MirrorClampToEdge, Repeat, MirrorRepeat, ClampToZero, ClampToBorder */
	uint32_t mag = s ? s.magFilter == MTLSamplerMinMagFilterLinear : 1, min = s ? s.minFilter == MTLSamplerMinMagFilterLinear : 1;
	uint32_t ws = s ? wrap[MIN((NSUInteger)s.sAddressMode, 5u)] : 1, wt = s ? wrap[MIN((NSUInteger)s.tAddressMode, 5u)] : 1;
	uint32_t wr = s ? wrap[MIN((NSUInteger)s.rAddressMode, 5u)] : 1;
	BOOL miplin = s && s.mipFilter == MTLSamplerMipFilterLinear;
	float maxl = s && s.mipFilter != MTLSamplerMipFilterNotMipmapped ? MIN(s.lodMaxClamp, 15.99f) : 0;
	float minl = s ? MIN(MAX(s.lodMinClamp, 0), 15.99f) : 0;
	d[0] = (miplin ? 1u : 0) | mag << 1 | min << 3 | ws << 5 | wt << 8 | wr << 11;
	d[1] = (miplin ? 1u << 6 : 0) | ((uint32_t)(maxl * 256) & 0xfff) << 8 | ((uint32_t)(minl * 256) & 0xfff) << 20;
	d[2] = 0;
	d[3] = 0;
}

/* Buffers: CPU memory for now. */

@implementation SweetMTLBuffer {
@public
	void *_mem;
	struct sg_bo _bo;	/* GPU memory (map = contents), when there is a GPU */
	BOOL _gpu;
	void *_ext;		/* newBufferWithBytesNoCopy: the caller's memory, copied into _bo when the GPU uses it */
	void (^_dealloc)(void *, NSUInteger);
}
+ (void)initialize
{
	if (self == [SweetMTLBuffer class]) {
		static const char *const pr[] = { "MTLBuffer", "MTLBufferSPI", NULL };
		route_class(self, NULL, pr);
	}
}
ROUTED(NULL)

- (instancetype)initWithDevice:(id)dev length:(NSUInteger)len options:(MTLResourceOptions)opt
{
	if ((self = [super init])) {
		_device = dev;
		_length = len;
		_resourceOptions = opt;
		SweetGPU *g = [SweetGPU shared];
		if (g && [g alloc:(len + 4095) & ~4095ull bo:&_bo]) {
			_gpu = YES;
			_mem = _bo.map;
		} else {
			_mem = calloc(1, len ?: 1);
		}
	}
	return self;
}
- (instancetype)initWithDevice:(id)dev bytesNoCopy:(void *)p length:(NSUInteger)len options:(MTLResourceOptions)opt
			   deallocator:(void (^)(void *, NSUInteger))dealloc
{
	if ((self = [self initWithDevice:dev length:len options:opt])) {
		_ext = p;
		_dealloc = [dealloc copy];
	}
	return self;
}
/* Before the GPU reads it: a no-copy buffer's current contents into GPU memory */
- (void)sweetSync
{
	if (_ext && _gpu)
		memcpy(_bo.map, _ext, _length);
}
- (void)dealloc
{
	if (_gpu)
		sg_bo_free([SweetGPU shared].dev, &_bo);
	else
		free(_mem);
	if (_dealloc)
		_dealloc(_ext, _length);
}
- (void *)contents { return _ext ?: _mem; }
- (const struct sg_bo *)bo { return _gpu ? &_bo : NULL; }
- (void)didModifyRange:(NSRange)r {}
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_resourceOptions & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_resourceOptions & MTLResourceCPUCacheModeMask); }
- (NSUInteger)allocatedSize { return _length; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)st { return MTLPurgeableStateNonVolatile; }
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)off bytesPerRow:(NSUInteger)bpr
{
	return [[SweetMTLTexture alloc] initWithDevice:_device descriptor:d buffer:self offset:off bytesPerRow:bpr];
}
- (id)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)off bytesPerRow:(NSUInteger)bpr
		       bytesPerImage:(NSUInteger)bpi
{
	return [[SweetMTLTexture alloc] initWithDevice:_device descriptor:d buffer:self offset:off bytesPerRow:bpr];
}
- (uint64_t)gpuAddress { return _gpu ? _bo.va : (uint64_t)(uintptr_t)_mem; }
@end

/* Simple state objects: the descriptor is all a later draw needs. */
@interface SweetMTLState : NSObject
@property (weak) id device;
@property (copy) NSString *label;
@property (strong) id descriptor;
@end
@implementation SweetMTLState
+ (void)initialize
{
	if (self == [SweetMTLState class]) {
		static const char *const pr[] = { "MTLDepthStencilState", "MTLSamplerState", NULL };
		route_class(self, NULL, pr);
	}
}
ROUTED(NULL)
@end

/* Render pipelines: which shader pair CA builds (the set of shaders to support), compiled later. */
@interface SweetMTLRenderPipelineState : NSObject
@property (weak) id device;
@property (copy) NSString *label;
@property (strong) MTLRenderPipelineDescriptor *descriptor;
@property (strong) SweetPipelineTemplate *tmpl;	/* nil: not drawn yet */
@property (copy) NSString *tmplName;			/* the template it would use */
@property BOOL writesNothing;				/* the attachment it draws to has write mask 0 */
@end
@implementation SweetMTLRenderPipelineState
+ (void)initialize
{
	if (self == [SweetMTLRenderPipelineState class]) {
		static const char *const pr[] = { "MTLRenderPipelineState", "MTLRenderPipelineStateSPI", NULL };
		route_class(self, NULL, pr);
	}
}
ROUTED(NULL)
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 1024; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
@end

/* Encoders: record nothing yet, but count what CA encodes per frame. */
@interface SweetMTLRenderCommandEncoder : _MTLCommandEncoder
@end
static int enc_logged;	/* render passes summarised so far (the first 40) */

/* Activity per 5 s (logged from the submit path while it is busy). */
static struct { unsigned cbs, passes, blits, draws, gpu_draws, gpu_passes; double t0, encode_ms; } act;
static NSCountedSet *act_missing;	/* why draws were not done on the GPU (template names: no template) */
static void act_skip(NSString *why)
{
	if (!act_missing)
		act_missing = [NSCountedSet new];
	[act_missing addObject:why];
}
static void act_tick(void)
{
	double now = [NSDate timeIntervalSinceReferenceDate];
	if (!act.t0)
		act.t0 = now;
	if (now - act.t0 >= 5) {
		NSMutableString *top = [NSMutableString string];
		NSArray *ms = [act_missing.allObjects sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
			return [@([act_missing countForObject:b]) compare:@([act_missing countForObject:a])];
		}];
		for (NSUInteger i = 0; i < MIN(ms.count, 6u); i++)
			[top appendFormat:@" %@x%lu", ms[i], (unsigned long)[act_missing countForObject:ms[i]]];
		mlog("5s: %u command buffers, %u render passes (%u on the GPU), %u draws (%u on the GPU), %u blit passes;"
		     " encode %.0f ms, submit: cache %.0f ms (%llu MB) GPU %.0f ms; not on the GPU:%s", act.cbs, act.passes, act.gpu_passes, act.draws,
		     act.gpu_draws, act.blits, act.encode_ms, sweet_stat_flush_ms, sweet_stat_flush_bytes >> 20, sweet_stat_gpu_ms, top.UTF8String);
		sweet_stat_flush_ms = sweet_stat_gpu_ms = 0;
		sweet_stat_flush_bytes = 0;
		[act_missing removeAllObjects];
		memset(&act, 0, sizeof(act));
		act.t0 = now;
	}
}

static int draws_dumped;	/* draws whose arguments were logged (the first 12) */
static int dump_left;		/* draws still to log after `touch /var/local/mtl-dump` */

static NSString *hexdump(const void *p, NSUInteger n)
{
	NSMutableString *s = [NSMutableString string];
	const uint32_t *w = p;
	for (NSUInteger i = 0; i < n / 4 && i < 48; i++)
		[s appendFormat:@"%s%08x", i ? " " : "", w[i]];
	return s;
}

@implementation SweetMTLRenderCommandEncoder {
@public
	MTLRenderPassDescriptor *_pass;
	unsigned _draws, _pipes, _tex;
	NSMutableString *_names;
	SweetMTLRenderPipelineState *_ps;
	NSMutableDictionary *_vbytes, *_fbytes;	/* index -> NSData */
	NSMutableDictionary *_vbufs, *_fbufs;	/* index -> [buffer, offset] */
	NSMutableDictionary *_fsmp;		/* index -> sampler state */
	NSMutableDictionary *_ftex;		/* index -> texture */
	SweetCmdStream *_stream;		/* the command buffer's; nil without a GPU */
	BOOL _gpuPass;				/* a GPU pass was begun for this encoder */
	struct sweet_target _target;
	float _vp[6];
	uint32_t _sc[4];
	BOOL _hasVp, _hasSc;
}
+ (void)initialize
{
	if (self == [SweetMTLRenderCommandEncoder class]) {
		static const char *const pr[] = { "MTLRenderCommandEncoder", "MTLRenderCommandEncoderSPI", NULL };
		route_class(self, "_MTLCommandEncoder", pr);
	}
}
ROUTED("_MTLCommandEncoder")

/* Metal semantics: the last binding at an index wins, bytes or buffer */
- (void)setVertexBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i
{
	if (!_vbytes)
		_vbytes = [NSMutableDictionary new];
	_vbytes[@(i)] = [NSData dataWithBytes:b length:n];
	[_vbufs removeObjectForKey:@(i)];
}
- (void)setFragmentBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i
{
	if (!_fbytes)
		_fbytes = [NSMutableDictionary new];
	_fbytes[@(i)] = [NSData dataWithBytes:b length:n];
	[_fbufs removeObjectForKey:@(i)];
}
- (void)setVertexBuffer:(id)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{
	if (!_vbufs)
		_vbufs = [NSMutableDictionary new];
	_vbufs[@(i)] = b ? @[ b, @(o) ] : @[];
	[_vbytes removeObjectForKey:@(i)];
}
- (void)setFragmentBuffer:(id)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{
	if (!_fbufs)
		_fbufs = [NSMutableDictionary new];
	_fbufs[@(i)] = b ? @[ b, @(o) ] : @[];
	[_fbytes removeObjectForKey:@(i)];
}
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i
{
	NSArray *bo = _vbufs[@(i)];
	if (bo.count == 2)
		_vbufs[@(i)] = @[ bo[0], @(o) ];
}
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i
{
	NSArray *bo = _fbufs[@(i)];
	if (bo.count == 2)
		_fbufs[@(i)] = @[ bo[0], @(o) ];
}
- (void)setFragmentSamplerState:(id)st atIndex:(NSUInteger)i
{
	if (!_fsmp)
		_fsmp = [NSMutableDictionary new];
	if (st)
		_fsmp[@(i)] = st;
	else
		[_fsmp removeObjectForKey:@(i)];
}

- (void)setViewport:(MTLViewport)v
{
	_vp[0] = (float)v.originX; _vp[1] = (float)v.originY; _vp[2] = (float)v.width; _vp[3] = (float)v.height;
	_vp[4] = (float)v.znear; _vp[5] = (float)v.zfar;
	_hasVp = YES;
}
- (void)setScissorRect:(MTLScissorRect)r
{
	_sc[0] = (uint32_t)r.x; _sc[1] = (uint32_t)r.y; _sc[2] = (uint32_t)r.width; _sc[3] = (uint32_t)r.height;
	_hasSc = YES;
}

/* Begin the GPU pass: the colour target in a format the host makes templates for, in GPU memory. */
- (void)beginGPUPass:(SweetCmdStream *)stream
{
	_stream = stream;
	SweetMTLTexture *t = (SweetMTLTexture *)_pass.colorAttachments[0].texture;
	/* formats the host makes templates for (tools/mtl-templates.py PIX) */
	NSUInteger f = t.pixelFormat;
	if (!stream || ![t isKindOfClass:[SweetMTLTexture class]] || !(f == 80 || f == 70 || f == 10 || f == 115 || f == 43 || f == 40))
		return;
	_target.fmt6 = sweet_fmt6(f);
	_target.va = [t sweetVA];
	_target.width = (uint32_t)t.width;
	_target.height = (uint32_t)t.height;
	_target.pitch = (uint32_t)t.bytesPerRow;
	if (_target.va && !(_target.pitch & 63) && !(_target.va & 63))
		_gpuPass = [stream beginPass:&_target];
	if (_gpuPass && _pass.colorAttachments[0].loadAction == MTLLoadActionClear)
		[self gpuClear:_pass.colorAttachments[0].clearColor];
	if (TRACE_TEX(t))
		mlog("trace: pass into %p load %lu gpu %d", t, (unsigned long)_pass.colorAttachments[0].loadAction, _gpuPass);
}

/*
 * Debugging: with /var/local/mtl-readback holding "WxH", the next GPU pass into a WxH target leaves its
 * colour target and CA's attachment 1 (the shared scratch, as this pass laid it out) in
 * /var/local/rb-att0.raw and rb-att1.raw (BGRA rows of the pitch in rb-info.txt), copied on the GPU right
 * after the pass. One-shot: the trigger file is removed.
 */
- (void)readbackIfWanted:(BOOL)afterDraw
{
	static char want[32];
	int fd = open("/var/local/mtl-readback", O_RDONLY);
	if (fd < 0)
		return;
	ssize_t n = read(fd, want, sizeof(want) - 1);
	close(fd);
	if (n <= 0)
		return;
	want[n] = 0;
	/*
	 * "WxH": at the end of the pass; "WxH MIN": the same, for a pass of at least MIN draws; "WxH @N": after
	 * draw N; "WxH #HASH": after the first draw with that template.
	 */
	unsigned w = 0, h = 0, num = 0;
	char hash[16] = "";
	BOOL at = strchr(want, '@') != NULL, byhash = strchr(want, '#') != NULL;
	if (byhash) {	/* "WxH #HASH [TEXW]": TEXW = width of the bound fragment texture 3 */
		unsigned tw = 0;
		if (sscanf(want, "%ux%u #%12s %u", &w, &h, hash, &tw) < 3 || !afterDraw || ![_ps.tmplName isEqualToString:@(hash)] ||
		    (tw && [(id<MTLTexture>)_ftex[@3] width] != tw))
			return;
	} else if (sscanf(want, at ? "%ux%u @%u" : "%ux%u %u", &w, &h, &num) < 2 || afterDraw != at ||
		   (at ? _draws != num : _draws < num))
		return;
	if (w != _target.width || h != _target.height)
		return;
	unlink("/var/local/mtl-readback");
	uint32_t len = _target.pitch * _target.height;
	SweetGPU *g = [SweetGPU shared];
	struct sg_bo *bo = calloc(2, sizeof(*bo));
	if (![g alloc:(len + 4095) & ~4095u bo:&bo[0]] || ![g alloc:(len + 4095) & ~4095u bo:&bo[1]])
		return;
	[_stream copyGPU:_target.va to:bo[0].va bytes:len];
	[_stream copyGPU:[g scratchTargetVA:len] to:bo[1].va bytes:len];
	uint32_t pitch = _target.pitch;
	[_stream afterGPU:^{
		for (int i = 0; i < 2; i++) {
			sg_cache_flush(g.dev, &bo[i], 0, len);
			char path[64];
			snprintf(path, sizeof(path), "/var/local/rb-att%d.raw", i);
			FILE *f = fopen(path, "wb");
			if (f) {
				fwrite(bo[i].map, 1, len, f);
				fclose(f);
			}
		}
		FILE *f = fopen("/var/local/rb-info.txt", "w");
		if (f) {
			fprintf(f, "%u %u %u\n", w, h, pitch);
			fclose(f);
		}
		mlog("readback: %ux%u pitch %u -> /var/local/rb-att0.raw, rb-att1.raw", w, h, pitch);
	}];
}

/*
 * MTLLoadActionClear: one quad over the whole target with the hand-made fixed_color template (no blending):
 * clip-space corners, identity MVP (vertex buffer 2), the clear colour as the vertex colour.
 */
- (void)gpuClear:(MTLClearColor)cc
{
	static SweetPipelineTemplate *tp;
	if (!tp)
		tp = [SweetPipelineTemplate named:@"fixed_color"];
	if (!tp)
		return;
	uint8_t vb[4 * 48];
	memset(vb, 0, sizeof(vb));
	static const float xy[4][2] = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } };
	_Float16 c[4] = { (_Float16)cc.red, (_Float16)cc.green, (_Float16)cc.blue, (_Float16)cc.alpha };
	for (int i = 0; i < 4; i++) {
		float p[4] = { xy[i][0], xy[i][1], 0, 1 };
		memcpy(vb + i * 48, p, 16);
		memcpy(vb + i * 48 + 32, c, 8);
	}
	static const float mvp[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
	static const uint16_t idx[6] = { 0, 1, 2, 2, 1, 3 };
	struct sweet_draw d;
	memset(&d, 0, sizeof(d));
	d.vb_va[1] = [_stream scratch:vb length:sizeof(vb)];
	d.vb_size[1] = sizeof(vb);
	d.vubo_va[2] = [_stream scratch:mvp length:sizeof(mvp)];
	d.vubo_size[2] = sizeof(mvp);
	d.ib_va = [_stream scratch:idx length:sizeof(idx)];
	d.index_count = 6;
	d.viewport[2] = _target.width;
	d.viewport[3] = _target.height;
	d.viewport[5] = 1;
	d.scissor[2] = _target.width;
	d.scissor[3] = _target.height;
	d.prim = 4;
	if (d.vb_va[1] && d.vubo_va[2] && d.ib_va)
		[_stream draw:&d template:tp];
}

/* A buffer binding as a GPU address + size (setXBytes data copied into the stream's memory). */
- (BOOL)resolve:(NSDictionary *)bufs bytes:(NSDictionary *)bytes index:(NSUInteger)i va:(uint64_t *)va size:(uint32_t *)size
{
	NSArray *bo = bufs[@(i)];
	NSData *b = bytes[@(i)];
	if (bo.count == 2) {
		SweetMTLBuffer *buf = bo[0];
		NSUInteger off = [bo[1] unsignedIntegerValue];
		if (![buf isKindOfClass:[SweetMTLBuffer class]] || !buf.bo)
			return NO;
		[buf sweetSync];
		[_stream keep:buf];
		[_stream touch:buf.bo];
		*va = buf.gpuAddress + off;
		*size = (uint32_t)MIN(buf.length - off, 65536u);
		return YES;
	}
	if (b) {
		*va = [_stream scratch:b.bytes length:(uint32_t)b.length];
		*size = (uint32_t)b.length;
		return *va != 0;
	}
	return NO;
}

/* Metal primitive -> DI_PT (0 = not drawable here) */
static uint32_t sweet_prim(MTLPrimitiveType t)
{
	static const uint32_t pt[] = { 9, 2, 3, 4, 6 };	/* point, line, line strip, triangle, triangle strip */
	return (NSUInteger)t < 5 ? pt[t] : 0;
}

- (void)gpuDrawIndexed:(NSUInteger)count type:(MTLIndexType)it buffer:(SweetMTLBuffer *)ib offset:(NSUInteger)off
{
	[self gpuDraw:MTLPrimitiveTypeTriangle count:count instances:1 first:0 indexType:it buffer:ib offset:off];
}

/* One draw on the GPU: indexed when ib is given, else vertices first..first+count-1 */
- (void)gpuDraw:(MTLPrimitiveType)pt count:(NSUInteger)count instances:(NSUInteger)ic first:(NSUInteger)first
      indexType:(MTLIndexType)it buffer:(SweetMTLBuffer *)ib offset:(NSUInteger)off
{
	double t0 = CFAbsoluteTimeGetCurrent();
	[self gpuDrawTimed:pt count:count instances:ic first:first indexType:it buffer:ib offset:off];
	act.encode_ms += (CFAbsoluteTimeGetCurrent() - t0) * 1000;
}

- (void)gpuDrawTimed:(MTLPrimitiveType)pt count:(NSUInteger)count instances:(NSUInteger)ic first:(NSUInteger)first
      indexType:(MTLIndexType)it buffer:(SweetMTLBuffer *)ib offset:(NSUInteger)off
{
	if (!sweet_prim(pt) || first) {
		act_skip(first ? @"first-vertex" : [NSString stringWithFormat:@"prim%lu", (unsigned long)pt]);
		return;		/* (first vertex: VFD_INDEX_OFFSET not patched yet) */
	}
	if (_gpuPass && !_ps.tmpl) {
		if (!act_missing)
			act_missing = [NSCountedSet new];
		[act_missing addObject:[NSString stringWithFormat:@"%@(%@)", _ps.tmplName,
					[_ps.descriptor.fragmentFunction.name stringByReplacingOccurrencesOfString:@"_lph" withString:@""]]];
	}
	if (_ps.writesNothing)
		return;		/* no colour writes to the attachment we model (e.g. clears of the memoryless one) */
	/* lines need the rasterizer state of a line pipeline: their own capture (<template>-l) */
	SweetPipelineTemplate *tp = _ps.tmpl;
	if (tp && (pt == MTLPrimitiveTypeLine || pt == MTLPrimitiveTypeLineStrip || pt == MTLPrimitiveTypePoint)) {
		tp = pt == MTLPrimitiveTypePoint ? nil : [SweetPipelineTemplate named:[_ps.tmplName stringByAppendingString:@"-l"]];
		if (!tp) {
			act_skip([NSString stringWithFormat:@"%@-%@", pt == MTLPrimitiveTypePoint ? @"points" : @"lines", _ps.tmplName]);
			return;
		}
	}
	if (!_gpuPass || !_ps.tmpl || (ib && (![ib isKindOfClass:[SweetMTLBuffer class]] || !ib.bo))) {
		if (!_gpuPass)
			act_skip(@"pass-not-on-gpu");
		else if (_ps.tmpl)
			act_skip(@"index-buffer");
		return;
	}
	struct sweet_draw d;
	memset(&d, 0, sizeof(d));
	for (NSUInteger i = 0; i < 8; i++) {
		if ([self resolve:_vbufs bytes:_vbytes index:i va:&d.vb_va[i] size:&d.vb_size[i]]) {
			d.vubo_va[i] = d.vb_va[i];
			d.vubo_size[i] = d.vb_size[i];
		}
		[self resolve:_fbufs bytes:_fbytes index:i va:&d.fubo_va[i] size:&d.fubo_size[i]];
	}
	if (_hasVp)
		memcpy(d.viewport, _vp, sizeof(_vp));
	else {
		d.viewport[2] = _target.width;
		d.viewport[3] = _target.height;
		d.viewport[5] = 1;
	}
	if (_hasSc)
		memcpy(d.scissor, _sc, sizeof(_sc));
	else {
		d.scissor[2] = _target.width;
		d.scissor[3] = _target.height;
	}
	/* debug (file /var/local/mtl-tint): templated quads red, to see GPU output on the panel */
	static int tint = -1;
	if (tint < 0)
		tint = access("/var/local/mtl-tint", F_OK) == 0;
	NSArray *vb = _vbufs[@1];
	if (tint && vb.count == 2 && [vb[0] isKindOfClass:[SweetMTLBuffer class]]) {
		SweetMTLBuffer *b = vb[0];
		uint8_t *v = (uint8_t *)b.contents + [vb[1] unsignedIntegerValue];
		static const uint16_t red[4] = { 0x3c00, 0, 0, 0x3c00 };	/* half4 rgba */
		for (int k = 0; k < 4 && [vb[1] unsignedIntegerValue] + k * 48 + 40 <= b.length; k++)
			memcpy(v + k * 48 + 32, red, 8);
	}
	/* textures and samplers the template's fragment shader uses (air2glsl's map) */
	NSDictionary *res = tp.res;
	for (NSString *k in res[@"textures"]) {
		int i = k.intValue;
		SweetMTLTexture *t = _ftex[@(i)];
		if (i >= 16 || ![t isKindOfClass:[SweetMTLTexture class]] || !sweet_tex_desc(t, d.tex[i])) {
			act_skip([NSString stringWithFormat:@"texture-fmt%lu", (unsigned long)t.pixelFormat]);
			static int logged;
			if (logged++ < 10)
				mlog("draw skipped: texture %d %s", i, t ? [NSString stringWithFormat:@"fmt %lu %lux%lu bpr %lu va %llx%s",
				     (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height,
				     (unsigned long)t.bytesPerRow, [t isKindOfClass:[SweetMTLTexture class]] ? [t sweetVA] : 0,
				     [t isKindOfClass:[SweetMTLTexture class]] && t.iosurface ? " iosurface" : ""].UTF8String : "unbound");
			return;
		}
		d.tex_mask |= 1u << i;
		[_stream keep:t];
		const struct sg_bo *bo = [t sweetBO];
		if (bo && [t sweetNeedsClean])
			[_stream touch:bo];
	}
	/* CA's memoryless attachment 1 (DontCare load/store): one scratch buffer the size of the target */
	uint64_t att1 = 0;
	if ([res[@"dest"] intValue] == 1 || [res[@"fbfetch"] containsObject:@1])
		att1 = [[SweetGPU shared] scratchTargetVA:(uint64_t)_target.pitch * _target.height];
	if ([res[@"dest"] intValue] == 1) {
		if (!att1)
			return;
		d.dest_va = att1;
	}
	if ([res[@"fbfetch"] count]) {
		/* attachment 0 (texture 15) / 1 (texture 14) as BGRA8 textures, read with texelFetch; sampler 23 nearest */
		for (NSNumber *n in res[@"fbfetch"]) {
			uint64_t va = n.intValue ? att1 : _target.va;
			uint32_t *t = d.tex[15 - n.intValue];
			memset(t, 0, 64);
			uint32_t f6 = n.intValue ? 0x130 : _target.fmt6;	/* attachment 1: BGRA8 */
			t[0] = (0u | 1u << 3 | 2u << 6 | 3u << 9) << 4 | (f6 & 0xff) << 22 | ((f6 >> 8) & 3) << 30;
			t[1] = (_target.width & 0x7fff) | (_target.height & 0x7fff) << 15;
			t[2] = _target.pitch << 7 | 1u << 29;
			t[3] = (_target.pitch * _target.height) >> 12;
			t[4] = (uint32_t)va;
			t[5] = (uint32_t)(va >> 32) | 1u << 17;
			d.tex_mask |= 1u << (15 - n.intValue);
		}
		d.smp[23][0] = 1u << 5 | 1u << 8 | 1u << 11;	/* nearest, clamp to edge */
		d.smp[23][1] = d.smp[23][2] = d.smp[23][3] = 0;
		d.smp_mask |= 1u << 23;
		d.fbfetch = 1;
	}
	for (NSString *k in res[@"samplers"]) {
		int i = k.intValue;
		if (i >= 24)
			continue;
		SweetMTLState *st = i < 16 ? _fsmp[@(i)] : nil;	/* 16+: constexpr samplers (linear, clamp for now) */
		sweet_smp_desc([st isKindOfClass:[SweetMTLState class]] ? st.descriptor : nil, d.smp[i]);
		d.smp_mask |= 1u << i;
	}
	if (ib) {
		[ib sweetSync];
		[_stream keep:ib];
		[_stream touch:ib.bo];
	}
	[_stream keep:(id)_pass.colorAttachments[0].texture];
	act.gpu_draws++;
	/* touch /var/local/mtl-dump: the next 150 GPU draws (or the number in the file) are logged (once per new mtime) */
	static double dump_check;
	static time_t dump_mtime;
	double now = [NSDate timeIntervalSinceReferenceDate];
	struct stat st;
	if (!dump_left && now - dump_check > 1) {
		dump_check = now;
		if (stat("/var/local/mtl-dump", &st) == 0 && st.st_mtime != dump_mtime) {
			if (dump_mtime) {
				FILE *f = fopen("/var/local/mtl-dump", "r");
				int want = 0;
				if (f) {
					if (fscanf(f, "%d", &want) != 1)
						want = 0;
					fclose(f);
				}
				dump_left = want > 0 ? want : 150;
			}
			dump_mtime = st.st_mtime;
		}
	}
	if (dump_left) {
		dump_left--;
		NSMutableString *tx = [NSMutableString string];
		for (int i = 0; i < 16; i++)
			if (d.tex_mask & (1u << i)) {
				SweetMTLTexture *t = _ftex[@(i)];
				uint32_t sum = 0;
				const uint8_t *px = [(id)t sweetBytes];
				for (NSUInteger y = 0; px && y < t.height; y += 7)
					for (NSUInteger x = 0; x < MIN(t.bytesPerRow, 4096u); x += 13)
						sum += px[y * t.bytesPerRow + x];
				[tx appendFormat:@" t%d=%lux%lu/fmt%lu%s/bpr%lu/sum%u/va%llx", i, (unsigned long)t.width, (unsigned long)t.height,
				 (unsigned long)t.pixelFormat, t.iosurface ? "/ios" : "", (unsigned long)t.bytesPerRow, sum, [t sweetVA]];
			}
		NSArray *vb1 = _vbufs[@1];
		if (vb1.count == 2) {
			SweetMTLBuffer *b = vb1[0];
			NSUInteger o = [vb1[1] unsignedIntegerValue], stride = _ps.descriptor.vertexDescriptor.layouts[1].stride;
			const uint8_t *v = (const uint8_t *)b.contents + o;
			for (int k = 0; k < 4 && stride && o + (k + 1) * stride <= b.length; k++) {
				const float *f = (const float *)(v + k * stride);
				const uint16_t *h = (const uint16_t *)(v + k * stride + (stride == 48 ? 32 : 8));
				mlog("dump:   v%d %.1f %.1f %.1f %.1f  %s c %04x %04x %04x %04x", k, f[0], f[1], stride == 48 ? f[2] : 0,
				     stride == 48 ? f[3] : 0, stride == 48 ? [NSString stringWithFormat:@"t %.3f %.3f", f[4], f[5]].UTF8String : "",
				     h[0], h[1], h[2], h[3]);
			}
		}
		mlog("dump: prim %lu count %lu inst %lu indexed %d", (unsigned long)pt, (unsigned long)count, (unsigned long)ic, ib != nil);
		mlog("dump: %s %s vp %.0f,%.0f %.0fx%.0f sc %u,%u %ux%u%s", _ps.tmplName.UTF8String,
		     [_ps.descriptor.fragmentFunction.name stringByReplacingOccurrencesOfString:@"_lph" withString:@""].UTF8String,
		     d.viewport[0], d.viewport[1], d.viewport[2], d.viewport[3], d.scissor[0], d.scissor[1], d.scissor[2],
		     d.scissor[3], tx.UTF8String);
	}
	d.ib_va = ib ? ib.gpuAddress + off : 0;
	d.index_count = (uint32_t)count;
	d.index_u32 = it == MTLIndexTypeUInt32;
	d.instances = (uint32_t)ic;
	d.prim = sweet_prim(pt);
	[_stream draw:&d template:tp];
	[self readbackIfWanted:YES];
}

/* The arguments of one draw, for learning CA's runtime layout. */
- (void)dumpDraw:(NSString *)what
{
	if (draws_dumped >= 12)
		return;
	draws_dumped++;
	mlog("draw %d: %s pipeline %s + %s", draws_dumped, what.UTF8String,
	     _ps.descriptor.vertexFunction.name.UTF8String, _ps.descriptor.fragmentFunction.name.UTF8String);
	for (NSNumber *i in _vbytes)
		mlog("  vbytes[%lu] %lu: %s", (unsigned long)i.unsignedLongValue, (unsigned long)[_vbytes[i] length], hexdump([_vbytes[i] bytes], [_vbytes[i] length]).UTF8String);
	for (NSNumber *i in _fbytes)
		mlog("  fbytes[%lu] %lu: %s", (unsigned long)i.unsignedLongValue, (unsigned long)[_fbytes[i] length], hexdump([_fbytes[i] bytes], [_fbytes[i] length]).UTF8String);
	for (NSNumber *i in _vbufs) {
		NSArray *bo = _vbufs[i];
		if (bo.count == 2) {
			SweetMTLBuffer *b = bo[0];
			NSUInteger off = [bo[1] unsignedIntegerValue];
			mlog("  vbuf[%lu] len %lu off %lu: %s", (unsigned long)i.unsignedLongValue, (unsigned long)b.length, (unsigned long)off,
			     hexdump((uint8_t *)b.contents + off, MIN(b.length - off, 96)).UTF8String);
		}
	}
	for (NSNumber *i in _fbufs) {
		NSArray *bo = _fbufs[i];
		if (bo.count == 2) {
			SweetMTLBuffer *b = bo[0];
			NSUInteger off = [bo[1] unsignedIntegerValue];
			mlog("  fbuf[%lu] len %lu off %lu: %s", (unsigned long)i.unsignedLongValue, (unsigned long)b.length, (unsigned long)off,
			     hexdump((uint8_t *)b.contents + off, MIN(b.length - off, 96)).UTF8String);
		}
	}
	for (NSNumber *i in _ftex) {
		SweetMTLTexture *t = _ftex[i];
		mlog("  ftex[%lu] %lux%lu fmt %lu%s", (unsigned long)i.unsignedLongValue, (unsigned long)t.width, (unsigned long)t.height,
		     (unsigned long)t.pixelFormat, t.iosurface ? " iosurface" : "");
	}
	MTLRenderPipelineColorAttachmentDescriptor *ca = _ps.descriptor.colorAttachments[0];
	if (ca.blendingEnabled)
		mlog("  blend rgb %lu: %lu,%lu alpha %lu: %lu,%lu", (unsigned long)ca.rgbBlendOperation,
		     (unsigned long)ca.sourceRGBBlendFactor, (unsigned long)ca.destinationRGBBlendFactor,
		     (unsigned long)ca.alphaBlendOperation, (unsigned long)ca.sourceAlphaBlendFactor,
		     (unsigned long)ca.destinationAlphaBlendFactor);
}

- (void)setRenderPipelineState:(SweetMTLRenderPipelineState *)ps
{
	_ps = ps;
	_pipes++;
	if (!_names)
		_names = [NSMutableString new];
	if (_names.length < 300)
		[_names appendFormat:@" %@", ps.descriptor.fragmentFunction.name];
}
- (void)setFragmentTexture:(id)t atIndex:(NSUInteger)i
{
	_tex++;
	if (!_ftex)
		_ftex = [NSMutableDictionary new];
	if (t)
		_ftex[@(i)] = t;
	else
		[_ftex removeObjectForKey:@(i)];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n
{
	_draws++;
	[self gpuDraw:t count:n instances:1 first:s indexType:MTLIndexTypeUInt16 buffer:nil offset:0];
	[self dumpDraw:[NSString stringWithFormat:@"prim %lu start %lu count %lu", (unsigned long)t, (unsigned long)s, (unsigned long)n]];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)ic
{
	_draws++;
	[self gpuDraw:t count:n instances:ic first:s indexType:MTLIndexTypeUInt16 buffer:nil offset:0];
	[self dumpDraw:[NSString stringWithFormat:@"prim %lu start %lu count %lu x%lu", (unsigned long)t, (unsigned long)s, (unsigned long)n, (unsigned long)ic]];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it
		  indexBuffer:(SweetMTLBuffer *)ib indexBufferOffset:(NSUInteger)off
{
	_draws++;
	[self gpuDraw:t count:n instances:1 first:0 indexType:it buffer:ib offset:off];
	[self dumpDraw:[NSString stringWithFormat:@"indexed prim %lu count %lu type %lu: %@", (unsigned long)t,
			(unsigned long)n, (unsigned long)it, hexdump((uint8_t *)ib.contents + off, MIN(n * (it ? 4 : 2), 48))]];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)it
		  indexBuffer:(SweetMTLBuffer *)ib indexBufferOffset:(NSUInteger)off instanceCount:(NSUInteger)ic
{
	_draws++;
	[self gpuDraw:t count:n instances:ic first:0 indexType:it buffer:ib offset:off];
	[self dumpDraw:[NSString stringWithFormat:@"indexed prim %lu count %lu x%lu", (unsigned long)t, (unsigned long)n, (unsigned long)ic]];
}

- (void)endEncoding
{
	if (dump_left) {
		SweetMTLTexture *t = (SweetMTLTexture *)_pass.colorAttachments[0].texture;
		MTLClearColor cc = _pass.colorAttachments[0].clearColor;
		mlog("dump: == pass %lux%lu fmt %lu%s va %llx load %lu store %lu clear %.2f,%.2f,%.2f,%.2f: %u draws, gpu %d",
		     (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, t.iosurface ? " ios" : "",
		     [t isKindOfClass:[SweetMTLTexture class]] ? [t sweetVA] : 0, (unsigned long)_pass.colorAttachments[0].loadAction,
		     (unsigned long)_pass.colorAttachments[0].storeAction, cc.red, cc.green, cc.blue, cc.alpha, _draws, _gpuPass);
	}
	act.passes++;
	act.draws += _draws;
	act.gpu_passes += _gpuPass;
	if (_gpuPass) {
		[_stream endPass];
		[self readbackIfWanted:NO];
	}
	if (enc_logged < 40 && (_draws || enc_logged < 20)) {
		enc_logged++;
		SweetMTLTexture *t = (SweetMTLTexture *)_pass.colorAttachments[0].texture;
		mlog("pass: target %lux%lu fmt %lu%s load %lu clear %.2f,%.2f,%.2f,%.2f: %u draws, %u pipelines, %u textures:%s",
		     (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, t.iosurface ? " (iosurface)" : "",
		     (unsigned long)_pass.colorAttachments[0].loadAction, _pass.colorAttachments[0].clearColor.red,
		     _pass.colorAttachments[0].clearColor.green, _pass.colorAttachments[0].clearColor.blue,
		     _pass.colorAttachments[0].clearColor.alpha, _draws, _pipes, _tex, (_names ?: @"").UTF8String);
		for (NSUInteger i = 1; i < 4; i++) {
			MTLRenderPassColorAttachmentDescriptor *a = _pass.colorAttachments[i];
			SweetMTLTexture *at = (SweetMTLTexture *)a.texture;
			if (at)
				mlog("  att%lu: %lux%lu fmt %lu%s load %lu store %lu", (unsigned long)i, (unsigned long)at.width,
				     (unsigned long)at.height, (unsigned long)at.pixelFormat, at.iosurface ? " (iosurface)" : "",
				     (unsigned long)a.loadAction, (unsigned long)a.storeAction);
		}
	}
	[super endEncoding];
}
@end

@interface SweetMTLBlitCommandEncoder : _MTLCommandEncoder
@end
/*
 * Blits run on the CPU when they are encoded. GPU work encoded before them in the same command buffer is
 * submitted first (synchronously), so they see its results; their writes are cleaned by the next draw's
 * cache maintenance (textures and buffers are touched when drawn with).
 */
@implementation SweetMTLBlitCommandEncoder
+ (void)initialize
{
	if (self == [SweetMTLBlitCommandEncoder class]) {
		static const char *const pr[] = { "MTLBlitCommandEncoder", "MTLBlitCommandEncoderSPI", NULL };
		route_class(self, "_MTLCommandEncoder", pr);
	}
}
ROUTED("_MTLCommandEncoder")

/* CPU view of a texture's level 0 (GPU writes made visible) */
static uint8_t *blit_tex(SweetMTLTexture *t)
{
	if (![t isKindOfClass:[SweetMTLTexture class]])
		return NULL;
	const struct sg_bo *bo = [t sweetBO];
	if (bo)
		sg_cache_flush([SweetGPU shared].dev, bo, 0, bo->size);
	return [(id)t sweetBytes];
}

- (void)copyFromTexture:(SweetMTLTexture *)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
	   sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz toTexture:(SweetMTLTexture *)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dor
{
	uint8_t *s = blit_tex(src), *d = blit_tex(dst);
	if (TRACE_TEX(dst))
		mlog("trace: blit texture %p -> %p", src, dst);
	if (!s || !d || sl || dl || ss || ds)
		return;
	[dst sweetMarkCPUWrite];
	NSUInteger px = sweet_bpp(src.pixelFormat);
	for (NSUInteger y = 0; y < sz.height && so.y + y < src.height && dor.y + y < dst.height; y++)
		memcpy(d + (dor.y + y) * dst.bytesPerRow + dor.x * px, s + (so.y + y) * src.bytesPerRow + so.x * px,
		       MIN(sz.width, MIN(src.width - so.x, dst.width - dor.x)) * px);
}

- (void)copyFromTexture:(SweetMTLTexture *)src toTexture:(SweetMTLTexture *)dst
{
	[self copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
		   sourceSize:MTLSizeMake(src.width, src.height, 1) toTexture:dst destinationSlice:0 destinationLevel:0
	    destinationOrigin:MTLOriginMake(0, 0, 0)];
}

- (void)copyFromBuffer:(SweetMTLBuffer *)src sourceOffset:(NSUInteger)off sourceBytesPerRow:(NSUInteger)bpr
     sourceBytesPerImage:(NSUInteger)bpi sourceSize:(MTLSize)sz toTexture:(SweetMTLTexture *)dst
	destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dor
{
	uint8_t *d = blit_tex(dst);
	if (TRACE_TEX(dst))
		mlog("trace: blit buffer -> %p", dst);
	if (!d || dl || ds)
		return;
	[dst sweetMarkCPUWrite];
	if (src.bo)
		sg_cache_flush([SweetGPU shared].dev, src.bo, 0, src.bo->size);
	const uint8_t *s = (const uint8_t *)src.contents + off;
	NSUInteger px = sweet_bpp(dst.pixelFormat);
	for (NSUInteger y = 0; y < sz.height && dor.y + y < dst.height; y++)
		memcpy(d + (dor.y + y) * dst.bytesPerRow + dor.x * px, s + y * bpr, MIN(sz.width, dst.width - dor.x) * px);
}

- (void)copyFromBuffer:(SweetMTLBuffer *)src sourceOffset:(NSUInteger)so toBuffer:(SweetMTLBuffer *)dst
       destinationOffset:(NSUInteger)doff size:(NSUInteger)n
{
	if (src.bo)
		sg_cache_flush([SweetGPU shared].dev, src.bo, 0, src.bo->size);
	if (so + n <= src.length && doff + n <= dst.length)
		memmove((uint8_t *)dst.contents + doff, (const uint8_t *)src.contents + so, n);
}

- (void)fillBuffer:(SweetMTLBuffer *)b range:(NSRange)r value:(uint8_t)v
{
	if (NSMaxRange(r) <= b.length)
		memset((uint8_t *)b.contents + r.location, v, r.length);
}

- (void)generateMipmapsForTexture:(id)t
{
	/* level 0 only: every texture is sampled with one mip level */
}
@end

/*
 * The queue: Metal's base class keeps the command buffer bookkeeping (commit ->
 * submitCommandBuffers:count:, completion handlers via completeCommandBuffers:
 * count:). Stage 2: buffers complete at once (no GPU work encoded yet).
 */
@interface SweetMTLCommandQueue : _MTLCommandQueue
@end
@interface SweetMTLCommandBuffer : _MTLCommandBuffer
- (SweetCmdStream *)sweetStream;
- (SweetCmdStream *)sweetStreamIfAny;
@end

@implementation SweetMTLCommandBuffer {
	SweetCmdStream *_stream;
}
- (SweetCmdStream *)sweetStream
{
	if (!_stream)
		_stream = [[SweetCmdStream alloc] initWithGPU:[SweetGPU shared]];
	return _stream;
}
- (SweetCmdStream *)sweetStreamIfAny
{
	return _stream;
}
+ (void)initialize
{
	if (self == [SweetMTLCommandBuffer class]) {
		static const char *const pr[] = { "MTLCommandBuffer", "MTLCommandBufferSPI", NULL };
		route_class(self, "_MTLCommandBuffer", pr);
	}
}
ROUTED("_MTLCommandBuffer")

/* the base has none; CA checks it against its device ("commandBuffer is associated with a different device") */
- (id)device
{
	return [[(id<MTLCommandBuffer>)self commandQueue] device];
}

- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d
{
	SweetMTLRenderCommandEncoder *e = [[SweetMTLRenderCommandEncoder alloc] initWithCommandBuffer:self];
	e->_pass = [d copy];
	[e beginGPUPass:[self sweetStream]];
	return e;
}

- (id)blitCommandEncoder
{
	act.blits++;
	[_stream submit];	/* earlier GPU work first: the blit runs on the CPU now */
	return [[SweetMTLBlitCommandEncoder alloc] initWithCommandBuffer:self];
}

- (id)blitCommandEncoderWithDescriptor:(id)d
{
	return [self blitCommandEncoder];
}
@end

@implementation SweetMTLCommandQueue {
	__weak id _sdevice;
	dispatch_queue_t _completionQueue;
}
+ (void)initialize
{
	if (self == [SweetMTLCommandQueue class]) {
		static const char *const pr[] = { "MTLCommandQueue", "MTLCommandQueueSPI", NULL };
		route_class(self, "_MTLCommandQueue", pr);
	}
}
ROUTED("_MTLCommandQueue")

- (id)initWithDevice:(id)device
{
	if ((self = [super initWithDevice:device]))
		_sdevice = device;
	return self;
}

- (id)device
{
	return _sdevice;
}

- (void)setCompletionQueue:(dispatch_queue_t)q
{
	_completionQueue = q;
}

- (dispatch_queue_t)completionQueue
{
	return _completionQueue;
}

- (void)setGPUPriority:(NSUInteger)p
{
}

- (id)commandBuffer
{
	return [[SweetMTLCommandBuffer alloc] initWithQueue:self retainedReferences:YES];
}

- (id)commandBufferWithUnretainedReferences
{
	return [[SweetMTLCommandBuffer alloc] initWithQueue:self retainedReferences:NO];
}

- (id)commandBufferWithDescriptor:(id)desc
{
	return [[SweetMTLCommandBuffer alloc] initWithQueue:self retainedReferences:YES];
}

- (void)submitCommandBuffers:(const id *)buffers count:(unsigned long long)count
{
	static int logged;
	if (!logged++)
		mlog("SweetMTLCommandQueue: first submit (%llu buffers)", count);
	act.cbs += count;
	act_tick();
	/* queued on the GPU now; completed in order on a serial queue once each fence lands */
	static dispatch_queue_t done;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		done = dispatch_queue_create("SweetMetal.completion", DISPATCH_QUEUE_SERIAL);
	});
	/* experiment: /var/local/mtl-sync (checked once a second) waits for each command buffer here */
	static double sync_check;
	static BOOL sync;
	double now = [NSDate timeIntervalSinceReferenceDate];
	if (now - sync_check > 1) {
		sync_check = now;
		sync = access("/var/local/mtl-sync", F_OK) == 0;
	}
	for (unsigned long long i = 0; i < count; i++) {
		id b = buffers[i];
		SweetCmdStream *st = [b sweetStreamIfAny];
		uint32_t fence = [st submitAsync];
		[b didScheduleWithStartTime:0 endTime:0 error:nil];
		if (sync) {
			[st retire:fence];
			dispatch_async(done, ^{
				id one = b;
				[self completeCommandBuffers:&one count:1];
			});
			continue;
		}
		dispatch_async(done, ^{
			[st retire:fence];
			id one = b;
			[self completeCommandBuffers:&one count:1];
		});
	}
}
@end

/*
 * Watch how clients specialise functions: the library is Metal's own (_MTLLibrary), so its function
 * creation methods are routed through forwardInvocation: on that class, logged, then run as before.
 */
static NSMutableDictionary *lib_orig;	/* selector -> NSValue(IMP) */
static char sweet_fc_key;		/* associated object: a function's MTLFunctionConstantValues */
static char sweet_lib_key;		/* associated object: a library's / function's metallib path (for the host) */
static int lib_logged;

/*
 * One specialisation of a library function: Metal's library hands out the same function object for a name
 * each time, so the constant values ride on a proxy of their own (else a later specialisation overwrites
 * an earlier one's before its pipeline is made).
 */
@interface SweetFnProxy : NSProxy
+ (id)proxyFor:(id)fn;
@end
@implementation SweetFnProxy {
	id _fn;
}
+ (id)proxyFor:(id)fn
{
	SweetFnProxy *p = [SweetFnProxy alloc];
	p->_fn = fn;
	return p;
}
- (id)forwardingTargetForSelector:(SEL)sel
{
	return _fn;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	return [_fn methodSignatureForSelector:sel];
}
- (void)forwardInvocation:(NSInvocation *)inv
{
	[inv invokeWithTarget:_fn];
}
@end

static void lib_forward(id self, SEL _cmd, NSInvocation *inv)
{
	NSValue *v = lib_orig[NSStringFromSelector(inv.selector)];
	if (!v) {
		[self doesNotRecognizeSelector:inv.selector];
		return;
	}
	if (lib_logged < 0) {	/* (set to 60 to watch function creation) */
		lib_logged++;
		__unsafe_unretained id a2 = nil, a3 = nil;
		[inv getArgument:&a2 atIndex:2];
		if (inv.methodSignature.numberOfArguments > 3 && *[inv.methodSignature getArgumentTypeAtIndex:3] == '@')
			[inv getArgument:&a3 atIndex:3];
		NSString *d2 = [[a2 description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
		NSString *d3 = [[a3 description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
		mlog("library -%s %.200s | %.400s", sel_getName(inv.selector), d2.UTF8String, d3 ? d3.UTF8String : "");
	}
	/*
	 * Specialisation: Metal's library needs a compiler backend for it (the async paths fail: "Metal
	 * failed to specialize fragment function"). We specialise when we compile the pipeline: return the
	 * plain function with the constant values attached, at once or through the completion handler.
	 */
	const char *sn = sel_getName(inv.selector);
	BOOL by_desc = !strncmp(sn, "newFunctionWithDescriptor:", 26);
	BOOL by_name_cv = !strncmp(sn, "newFunctionWithName:constantValues:", 35);
	if (by_desc || by_name_cv) {
		__unsafe_unretained id a2 = nil, a3 = nil;
		[inv getArgument:&a2 atIndex:2];
		NSString *name;
		id cv;
		if (by_desc) {
			name = [a2 name];
			cv = [a2 respondsToSelector:@selector(constantValues)] ? [a2 constantValues] : nil;
		} else {
			[inv getArgument:&a3 atIndex:3];
			name = a2;
			cv = a3;
		}
		IMP plain = (IMP)[lib_orig[@"newFunctionWithName:"] pointerValue];
		id fn = plain ? ((id (*)(id, SEL, id))plain)(self, @selector(newFunctionWithName:), name) : nil;
		if (fn && cv) {
			fn = [SweetFnProxy proxyFor:fn];
			objc_setAssociatedObject(fn, &sweet_fc_key, [cv copy], OBJC_ASSOCIATION_RETAIN);
		}
		if (fn)
			objc_setAssociatedObject(fn, &sweet_lib_key, objc_getAssociatedObject(self, &sweet_lib_key), OBJC_ASSOCIATION_RETAIN);
		NSError *err = fn ? nil : [NSError errorWithDomain:@"SweetMetal" code:2 userInfo:@{
			NSLocalizedDescriptionKey : [NSString stringWithFormat:@"no function %@", name] }];
		if (strstr(sn, "completionHandler:")) {
			__unsafe_unretained void (^h)(id, NSError *) = nil;
			[inv getArgument:&h atIndex:(NSInteger)inv.methodSignature.numberOfArguments - 1];
			if (h)
				h(fn, err);
		} else {
			if (!strcmp(inv.methodSignature.methodReturnType, "@")) {
				/* "new" returns +1: hand the caller its own reference */
				CFTypeRef r = fn ? CFBridgingRetain(fn) : NULL;
				[inv setReturnValue:&r];
			}
			if (!strstr(sn, "completionHandler")) {
				NSError *__autoreleasing *ep = NULL;
				NSUInteger n = inv.methodSignature.numberOfArguments;
				if (n > 3 && !strcmp([inv.methodSignature getArgumentTypeAtIndex:n - 1], "^@"))
					[inv getArgument:&ep atIndex:(NSInteger)n - 1];
				if (ep && err)
					*ep = err;
			}
		}
		return;
	}
	[inv invokeUsingIMP:(IMP)v.pointerValue];
	if (!strcmp(sel_getName(inv.selector), "newFunctionWithName:")) {
		__unsafe_unretained id fn = nil;
		[inv getReturnValue:&fn];
		if (fn)
			objc_setAssociatedObject(fn, &sweet_lib_key, objc_getAssociatedObject(self, &sweet_lib_key), OBJC_ASSOCIATION_RETAIN);
	}
}

static NSMethodSignature *lib_signature(id self, SEL _cmd, SEL sel)
{
	Method m = class_getInstanceMethod(object_getClass(self), sel);
	NSValue *v = lib_orig[NSStringFromSelector(sel)];
	if (v) {
		Class c = object_getClass(self);
		while (c && !(m = class_getInstanceMethod(c, sel)))
			c = class_getSuperclass(c);
	}
	return m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
}

static void wrap_library(id lib)
{
	static NSMutableSet *done;
	Class c = object_getClass(lib);
	if (!done)
		done = [NSMutableSet new];
	if ([done containsObject:NSStringFromClass(c)])
		return;
	[done addObject:NSStringFromClass(c)];
	if (!lib_orig)
		lib_orig = [NSMutableDictionary new];
	static const char *const sels[] = {
		"newFunctionWithName:", "newFunctionWithName:constantValues:error:",
		"newFunctionWithName:constantValues:completionHandler:",
		"newFunctionWithName:constantValues:pipelineLibrary:error:",
		"newFunctionWithName:constantValues:functionCache:specializedName:error:",
		"newFunctionWithName:constantValues:functionCache:specializedName:completionHandler:",
		"newFunctionWithDescriptor:error:", "newFunctionWithDescriptor:completionHandler:",
		"newFunctionWithDescriptor:destinationArchive:error:",
		"newFunctionWithDescriptor:destinationArchive:functionCache:completionHandler:",
	};
	for (unsigned i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
		SEL sel = sel_registerName(sels[i]);
		Method m = class_getInstanceMethod(c, sel);
		if (!m || lib_orig[@(sels[i])])
			continue;
		lib_orig[@(sels[i])] = [NSValue valueWithPointer:(void *)method_getImplementation(m)];
		/* add on c itself (an inherited method gets an override, not a change to the superclass) */
		if (!class_addMethod(c, sel, _objc_msgForward, method_getTypeEncoding(m)))
			method_setImplementation(m, _objc_msgForward);
	}
	class_replaceMethod(c, @selector(forwardInvocation:), (IMP)lib_forward, "v@:@");
	class_replaceMethod(c, @selector(methodSignatureForSelector:), (IMP)lib_signature, "@@::");
	mlog("watching %s's function creation", class_getName(c));
}

@implementation SweetMTLDevice

+ (void)initialize
{
	if (self != [SweetMTLDevice class])
		return;
	/* MTLAddDevice asserts conformsToProtocol: MTLDevice and MTLDeviceSPI. */
	static const char *const pr[] = { "MTLDevice", "MTLDeviceSPI", NULL };
	route_class(self, "_MTLDevice", pr);
	mlog("SweetMTLDevice: %lu selectors routed through the logger", (unsigned long)types.count);
}

/* No precompiled pipeline archives (MTLPipelineLibraryBuilder wants the AGX target): CA builds its own. */
- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)error
{
	mlog("newPipelineLibraryWithFilePath: %s -> none", path.UTF8String);
	if (error)
		*error = [NSError errorWithDomain:@"SweetMetal" code:1 userInfo:nil];
	return nil;
}

static IMP super_imp(SEL s)
{
	return class_getMethodImplementation(objc_getClass("_MTLDevice"), s);
}

static id lib_loaded(id lib, NSString *path)
{
	if (lib) {
		wrap_library(lib);
		if (path)
			objc_setAssociatedObject(lib, &sweet_lib_key, path, OBJC_ASSOCIATION_RETAIN);
	}
	return lib;
}

- (id)newLibraryWithURL:(NSURL *)url error:(NSError **)error
{
	return lib_loaded(((id (*)(id, SEL, id, NSError **))super_imp(_cmd))(self, _cmd, url, error), url.path);
}

- (id)newDefaultLibraryWithBundle:(NSBundle *)b error:(NSError **)error
{
	return lib_loaded(((id (*)(id, SEL, id, NSError **))super_imp(_cmd))(self, _cmd, b, error),
			  [b pathForResource:@"default" ofType:@"metallib"]);
}

- (id)newDefaultLibrary
{
	return lib_loaded(((id (*)(id, SEL))super_imp(_cmd))(self, _cmd),
			  [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"]);
}

- (id)newLibraryWithFile:(NSString *)f error:(NSError **)error
{
	return lib_loaded(((id (*)(id, SEL, id, NSError **))super_imp(_cmd))(self, _cmd, f, error), f);
}

/* A library from memory: saved under /var/local/mtl-libs (when that directory exists) so the host can get it */
- (id)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error
{
	NSString *path = nil;
	const void *bytes = NULL;
	size_t len = 0;
	dispatch_data_t flat = dispatch_data_create_map(data, &bytes, &len);
	if (flat && len) {
		uint8_t h[CC_SHA1_DIGEST_LENGTH];
		CC_SHA1(bytes, (CC_LONG)len, h);
		path = [NSString stringWithFormat:@"/var/local/mtl-libs/%02x%02x%02x%02x%02x%02x.metallib", h[0], h[1], h[2], h[3], h[4], h[5]];
		if (access(path.UTF8String, F_OK) != 0)
			[[NSData dataWithBytes:bytes length:len] writeToFile:path atomically:NO];
	}
	return lib_loaded(((id (*)(id, SEL, id, NSError **))super_imp(_cmd))(self, _cmd, data, error), path);
}

- (id)newDepthStencilStateWithDescriptor:(id)d
{
	SweetMTLState *st = [SweetMTLState new];
	st.device = self;
	st.descriptor = [d copy];
	return st;
}

- (id)newSamplerStateWithDescriptor:(id)d
{
	SweetMTLState *st = [SweetMTLState new];
	st.device = self;
	st.descriptor = [d copy];
	return st;
}

- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d
{
	return [[SweetMTLTexture alloc] initWithDevice:self descriptor:d iosurface:NULL plane:0];
}

- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)ios plane:(NSUInteger)plane
{
	return [[SweetMTLTexture alloc] initWithDevice:self descriptor:d iosurface:ios plane:plane];
}

- (id)newBufferWithLength:(NSUInteger)len options:(MTLResourceOptions)opt
{
	return [[SweetMTLBuffer alloc] initWithDevice:self length:len options:opt];
}

- (id)newBufferWithBytesNoCopy:(void *)p length:(NSUInteger)len options:(MTLResourceOptions)opt
		     deallocator:(void (^)(void *, NSUInteger))dealloc
{
	return [[SweetMTLBuffer alloc] initWithDevice:self bytesNoCopy:p length:len options:opt deallocator:dealloc];
}

- (id)newBufferWithBytes:(const void *)p length:(NSUInteger)len options:(MTLResourceOptions)opt
{
	SweetMTLBuffer *b = [[SweetMTLBuffer alloc] initWithDevice:self length:len options:opt];
	memcpy(b.contents, p, len);
	return b;
}

static NSMutableSet *pipes_seen;

/* MTLFunctionConstantValues as "name=value ..." (from its description: name:X;type:T;value:(V)) */
static NSString *sweet_fc_compact(id cv)
{
	NSString *d = [[[cv description] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
			componentsJoinedByString:@""];
	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"name:([A-Za-z0-9_]+);type:MTLDataType([A-Za-z0-9]+);value:\\(([^)]*)\\)"
									    options:0 error:nil];
	NSMutableString *o = [NSMutableString string];
	for (NSTextCheckingResult *m in [re matchesInString:d options:0 range:NSMakeRange(0, d.length)])
		[o appendFormat:@"%@%@=%@", o.length ? @" " : @"", [[d substringWithRange:[m rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"fc_" withString:@""],
				[d substringWithRange:[m rangeAtIndex:3]]];
	return o;
}

/* template name for a pipeline key: the first 12 hex digits of its SHA-1 (as tools/mtlkeys.py) */
static NSString *sweet_key_hash(NSString *k)
{
	const char *s = k.UTF8String;
	uint8_t h[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1(s, (CC_LONG)strlen(s), h);
	return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x", h[0], h[1], h[2], h[3], h[4], h[5]];
}

/*
 * Blend factors other than premultiplied source-over (One, OneMinusSourceAlpha, Add for colour and alpha),
 * as " bf srcRGB,dstRGB,rgbOp,srcA,dstA,alphaOp" (Metal enums): CA masks and some blend modes use them.
 * Empty for the usual case, so those keys stay as they were.
 */
static NSString *sweet_blend_factors(MTLRenderPipelineColorAttachmentDescriptor *ca)
{
	if (!ca.blendingEnabled ||
	    (ca.sourceRGBBlendFactor == MTLBlendFactorOne && ca.destinationRGBBlendFactor == MTLBlendFactorOneMinusSourceAlpha &&
	     ca.rgbBlendOperation == MTLBlendOperationAdd && ca.sourceAlphaBlendFactor == MTLBlendFactorOne &&
	     ca.destinationAlphaBlendFactor == MTLBlendFactorOneMinusSourceAlpha && ca.alphaBlendOperation == MTLBlendOperationAdd))
		return @"";
	return [NSString stringWithFormat:@" bf %lu,%lu,%lu,%lu,%lu,%lu", (unsigned long)ca.sourceRGBBlendFactor,
		(unsigned long)ca.destinationRGBBlendFactor, (unsigned long)ca.rgbBlendOperation,
		(unsigned long)ca.sourceAlphaBlendFactor, (unsigned long)ca.destinationAlphaBlendFactor,
		(unsigned long)ca.alphaBlendOperation];
}

- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error
{
	if (!pipes_seen)
		pipes_seen = [NSMutableSet new];
	NSString *k = [NSString stringWithFormat:@"%@ + %@ -> fmt %lu blend %d", d.vertexFunction.name,
			d.fragmentFunction.name, (unsigned long)d.colorAttachments[0].pixelFormat,
			d.colorAttachments[0].blendingEnabled];
	/* the uber shaders are specialised by function constants: those are the shaders to support */
	/* colour write masks other than RGBA (the key is unchanged for the usual 0xf) */
	if (d.colorAttachments[0].writeMask != MTLColorWriteMaskAll)
		k = [k stringByAppendingFormat:@" wm %lu", (unsigned long)d.colorAttachments[0].writeMask];
	k = [k stringByAppendingString:sweet_blend_factors(d.colorAttachments[0])];
	for (NSUInteger i = 1; i < 8; i++) {
		MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[i];
		if (ca.pixelFormat)
			k = [k stringByAppendingFormat:@" | att%lu fmt %lu blend %d%@%@", (unsigned long)i, (unsigned long)ca.pixelFormat,
			     ca.blendingEnabled, ca.writeMask != MTLColorWriteMaskAll ?
			     [NSString stringWithFormat:@" wm %lu", (unsigned long)ca.writeMask] : @"", sweet_blend_factors(ca)];
	}
	NSMutableString *fc = [NSMutableString string];
	id vfn = d.vertexFunction, ffn = d.fragmentFunction;
	id vv = vfn ? objc_getAssociatedObject(vfn, &sweet_fc_key) : nil, fv = ffn ? objc_getAssociatedObject(ffn, &sweet_fc_key) : nil;
	if (vv)
		[fc appendFormat:@" | vfc %@", sweet_fc_compact(vv)];
	if (fv)
		[fc appendFormat:@" | ffc %@", sweet_fc_compact(fv)];
	k = [k stringByAppendingString:fc];
	/* vertex layout: attribute index: format @offset buffer N; buffer N stride */
	NSMutableString *vd = [NSMutableString string];
	for (NSUInteger i = 0; i < 8; i++) {
		MTLVertexAttributeDescriptor *a = d.vertexDescriptor.attributes[i];
		if (a.format)
			[vd appendFormat:@" a%lu=fmt%lu@%lu/b%lu", (unsigned long)i, (unsigned long)a.format, (unsigned long)a.offset, (unsigned long)a.bufferIndex];
	}
	for (NSUInteger i = 0; i < 8; i++) {
		MTLVertexBufferLayoutDescriptor *l = d.vertexDescriptor.layouts[i];
		if (l.stride)
			[vd appendFormat:@" b%lu stride %lu step %lu", (unsigned long)i, (unsigned long)l.stride, (unsigned long)l.stepFunction];
	}
	if (vd.length)
		k = [k stringByAppendingFormat:@" | vd%@", vd];
	if (![pipes_seen containsObject:k]) {
		[pipes_seen addObject:k];
		const char *ks = k.UTF8String;
		size_t kl = strlen(ks);
		klog("pipeline %lu: %.500s", (unsigned long)pipes_seen.count, ks);
		for (size_t o = 500; o < kl; o += 500)
			klog("pipeline %lu+: %.500s", (unsigned long)pipes_seen.count, ks + o);
		NSString *vl = vfn ? objc_getAssociatedObject(vfn, &sweet_lib_key) : nil, *fl = ffn ? objc_getAssociatedObject(ffn, &sweet_lib_key) : nil;
		klog("pipeline %lu lib: %s | %s", (unsigned long)pipes_seen.count, vl ? vl.UTF8String : "?", fl ? fl.UTF8String : "?");
	}
	SweetMTLRenderPipelineState *ps = [SweetMTLRenderPipelineState new];
	ps.device = self;
	ps.descriptor = [d copy];
	ps.label = d.label;
	/* the host's template for exactly this key (tools/mtl-templates.py), else the hand-made fixed_color */
	ps.tmplName = sweet_key_hash(k);
	/* attachment 1: CA's dest_index=1, or attachment 0 masked off while 1 is written (attachment_clear) */
	BOOL dest1 = ([fv isKindOfClass:[MTLFunctionConstantValues class]] && [sweet_fc_compact(fv) containsString:@"dest_index=1"]) ||
	    (d.colorAttachments[0].writeMask == MTLColorWriteMaskNone && d.colorAttachments[1].pixelFormat != MTLPixelFormatInvalid &&
	     d.colorAttachments[1].writeMask != MTLColorWriteMaskNone);
	ps.writesNothing = d.colorAttachments[dest1 ? 1 : 0].writeMask == MTLColorWriteMaskNone;
	/* debugging: template hashes listed in /var/local/mtl-skip (one per line, read once per process) are not drawn */
	static NSSet *skip;
	static dispatch_once_t skip_once;
	dispatch_once(&skip_once, ^{
		NSString *s = [NSString stringWithContentsOfFile:@"/var/local/mtl-skip" encoding:NSUTF8StringEncoding error:nil];
		skip = [NSSet setWithArray:[s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @[]];
	});
	if ([skip containsObject:ps.tmplName]) {
		mlog("skipping pipeline %s (/var/local/mtl-skip)", ps.tmplName.UTF8String);
		ps.writesNothing = YES;
	}
	ps.tmpl = [SweetPipelineTemplate named:ps.tmplName];
	if (!ps.tmpl) {
		static NSMutableSet *missing;
		if (!missing)
			missing = [NSMutableSet new];
		if (![missing containsObject:k]) {
			[missing addObject:k];
			mlog("no template %s for pipeline %lu", sweet_key_hash(k).UTF8String, (unsigned long)pipes_seen.count);
		}
	}
	NSString *vcs = sweet_fc_compact(objc_getAssociatedObject(d.vertexFunction, &sweet_fc_key) ?: @""),
		 *fcs = sweet_fc_compact(objc_getAssociatedObject(d.fragmentFunction, &sweet_fc_key) ?: @"");
	if ([d.vertexFunction.name hasPrefix:@"fixed_vert"] && [d.fragmentFunction.name hasPrefix:@"fixed_frag"] &&
	    [vcs containsString:@"texcoord_count0=0"] && [vcs containsString:@"texcoord_count1=0"] &&
	    [fcs containsString:@"image_count=0"] && d.colorAttachments[0].pixelFormat == MTLPixelFormatBGRA8Unorm)
		ps.tmpl = ps.tmpl ?: [SweetPipelineTemplate named:@"fixed_color"];
	return ps;
}

/*
 * We present as an Apple GPU family (Metal's base answers): QuartzCore.metallib only has the half
 * precision (_lph) shaders those use, and CA then blends in its shaders with framebuffer fetch
 * (fc_framebuffer_fetch=1), which our compiler turns into a fetch from the colour attachment.
 * (Non-Apple families made CA ask for fixed_frag_lpf_cpf, which iOS does not ship.)
 */
- (NSUInteger)maxBufferLength
{
	return 256u << 20;
}

- (id)newCommandQueue
{
	return [[SweetMTLCommandQueue alloc] initWithDevice:self];
}

- (id)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n
{
	return [[SweetMTLCommandQueue alloc] initWithDevice:self];
}

- (id)newCommandQueueWithDescriptor:(id)desc
{
	return [[SweetMTLCommandQueue alloc] initWithDevice:self];
}

- (id)initWithAcceleratorPort:(mach_port_t)port
{
	mlog("initWithAcceleratorPort: %u", port);
	/*
	 * No device where the GPU cannot be opened (sandboxed extensions such as
	 * CollectionsPoster): MTLRegisterDevices skips a nil device, so CoreImage and
	 * VideoToolbox there take their CPU paths instead of rendering nothing.
	 */
	if (![SweetGPU shared]) {
		mlog("no GPU access: no Metal device in this process");
		return nil;
	}
	return [super init];
}

- (NSString *)name
{
	return @"Adreno 640 (SweetMetal)";
}

ROUTED("_MTLDevice")

@end
