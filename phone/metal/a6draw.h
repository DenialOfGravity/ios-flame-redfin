/*
 * SweetMetal's GPU side: draws on the A640 with state turnip generated for each pipeline (templates made on
 * the host: work/mesa/draw/capture.sh + tools/rdtemplate.py), through the kernel's SweetAccelerator user
 * client (sweetgpu.c). Sysmem rendering, synchronous submission.
 */
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#include "sweetgpu.h"

@interface SweetGPU : NSObject
@property (readonly) struct sg_dev *dev;
@property (readonly) uint64_t globalsVA;	/* turnip's global buffer, relocated */
+ (instancetype)shared;				/* nil when there is no SweetAccelerator */
- (BOOL)alloc:(uint64_t)size bo:(struct sg_bo *)bo;
- (uint64_t)vaForSurface:(IOSurfaceRef)s;	/* imported once per surface; 0 on failure */
- (const struct sg_bo *)boForSurface:(IOSurfaceRef)s;	/* the same import (for cache maintenance) */
- (void)sweepSurfaces;				/* drop imports of surfaces only we still hold */
- (uint64_t)scratchTargetVA:(uint64_t)bytes;	/* GPU memory for CA's memoryless attachment (shared, grows) */
@end

/* One pipeline's turnip state: static draw-state groups (shader addresses patched), dynamic ones built per draw. */
@interface SweetPipelineTemplate : NSObject
+ (instancetype)named:(NSString *)name;		/* <bundle>/pipelines/NAME.json, cached; nil if absent */
@property (readonly) NSDictionary *res;		/* air2glsl's resource map: textures {index: 2d|3d}, samplers {binding: v} */
@end

/* Per render pass: what the prologue needs to know about the colour target. */
struct sweet_target {
	uint64_t va;
	uint32_t width, height, pitch;
	uint32_t fmt6;		/* FMT6 | swap << 8 | srgb << 10 (SweetMetal's sweet_fmt6); 0 = BGRA8 as captured */
};

/* Per draw: the resources a template's dynamic groups and descriptors point at. */
struct sweet_draw {
	uint64_t vb_va[8];		/* Metal vertex buffer index -> GPU VA (0: unbound) */
	uint32_t vb_size[8];
	uint64_t vubo_va[8], fubo_va[8];	/* Metal vertex/fragment buffers as UBOs */
	uint32_t vubo_size[8], fubo_size[8];
	float viewport[6];		/* x, y, w, h, znear, zfar */
	uint32_t scissor[4];		/* x, y, w, h */
	uint64_t ib_va;			/* 0: not indexed (vertices 0..index_count-1 from first_vertex) */
	uint32_t index_count, index_u32;
	uint32_t instances;		/* 0 = 1 */
	uint32_t prim;			/* DI_PT_*: 4 triangle list (as captured), 6 strip */
	uint32_t tex[16][16];		/* set 2: A6XX texture descriptors by Metal fragment texture index */
	uint32_t smp[24][4];		/* set 3: A6XX sampler descriptors (16+: constexpr samplers) */
	uint32_t tex_mask, smp_mask;	/* which are filled (none: sets 2/3 not written) */
	uint32_t fbfetch;		/* the shader reads the colour target (texture 15): flush caches first */
	uint64_t dest_va;		/* != 0: draw into this buffer instead (CA's memoryless attachment 1) */
};

/* time spent in submit (ms, summed): cache maintenance, and GPU execution; flushed bytes */
extern double sweet_stat_flush_ms, sweet_stat_gpu_ms;
extern uint64_t sweet_stat_flush_bytes;

@interface SweetCmdStream : NSObject
- (instancetype)initWithGPU:(SweetGPU *)gpu;
- (uint64_t)scratch:(const void *)data length:(uint32_t)len;	/* copy into this stream's memory: GPU VA */
- (BOOL)beginPass:(const struct sweet_target *)t;
- (void)draw:(const struct sweet_draw *)d template:(SweetPipelineTemplate *)tp;
- (void)endPass;
- (void)touch:(const struct sg_bo *)bo;			/* CPU-written buffer the GPU reads: cleaned before submit */
- (void)keep:(id)obj;					/* a resource the stream uses: kept alive until submitted */
- (int)submit;					/* 0 = done (synchronous) */
- (uint32_t)submitAsync;			/* queued: its fence (0 = nothing queued); then -retire: */
- (void)retire:(uint32_t)fence;			/* wait for the fence, release what the work used */
- (void)copyGPU:(uint64_t)src to:(uint64_t)dst bytes:(uint32_t)len;	/* debugging: CP_MEMCPY after the draws so far */
- (void)afterGPU:(dispatch_block_t)b;			/* run once the GPU finished this stream's work */
@property (readonly) unsigned draws;
@end
