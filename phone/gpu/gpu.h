/*
 * The Adreno 640 from userland through /dev/pmem. The hardware code is the
 * kernel's own core (work/dxb/xnu/bsd/dev/sweet_a6xx.c, built into this
 * tool too); this layer adds what a shell tool needs: state that persists
 * between commands, named buffers, .rd capture, replay of Mesa captures,
 * tests, and devcoredump-style state dumps that Mesa's crashdec reads.
 *
 * State (pool PA, SMMU banks, ring pointer, buffers) persists in
 * /var/local/gpu/state, so every command is a separate process.
 */
#ifndef GPU_H
#define GPU_H
#include <stdint.h>
#include <stdio.h>
#include "sweet_a6xx.h"

#define GPU_STATE_PATH	"/var/local/gpu/state"
#define GPU_DIR		"/var/local/gpu"
#define GPU_FW_DIR	"/var/local/gpu/fw"

#define FB_W		1080
#define FB_H		2280
#define FB_STRIDE	4320		/* as ABL set up the panel */
#define FB_STRIDE_GPU	4352		/* 64-byte multiple: what the GPU can write */

#define MAX_BOS		64

struct gpu_bo {
	char name[24];
	uint64_t off, size;		/* in the pool */
};

struct gpu_state {
	uint32_t magic, version;
	struct a6_gpu hw;
	uint32_t submits;
	uint32_t nbo;
	uint64_t heap_next;
	struct gpu_bo bo[MAX_BOS];
	/* gpu replay: one /dev/pmem allocation per captured buffer, mapped at its iova */
	uint32_t nrep, pad;
	struct { uint64_t iova, pa, size; } rep[48];
};

extern struct gpu_state st;

/* Logging: stdout, and the kernel console (so the RAM log rescue keeps it). */
void glog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

static inline uint64_t pool_pa(uint64_t off) { return st.hw.pool_pa + off; }
static inline uint64_t pool_va(uint64_t off) { return A6_GVA_POOL + off; }

int gpu_up(int paint);			/* full bring-up + CP_MEM_WRITE test; once per boot */
int gpu_test(const char *which);	/* "memwrite", "paint", "blit", "fb" */
int gpu_attach(void);			/* load + validate the state; 0 = GPU up */
void gpu_save(void);
void gpu_status(void);
void gpu_dump(FILE *f, const char *reason);
int gpu_clear_fault(void);		/* 1 if there was an SMMU fault to clear */

struct gpu_bo *bo_get(const char *name);
struct gpu_bo *bo_new(const char *name, uint64_t size);	/* existing one if the name is taken */
static inline uint64_t bo_pa(const struct gpu_bo *b) { return pool_pa(b->off); }
static inline uint64_t bo_va(const struct gpu_bo *b) { return pool_va(b->off); }

/* Submit an IB already in GPU memory; waits for the fence. rd: .rd file path or NULL. */
int gpu_submit(uint64_t ib_va, uint32_t dwords, unsigned timeout_ms, const char *rd);
/* Write dwords into bo "ib" and submit them. */
int gpu_submit_dwords(const uint32_t *dw, uint32_t n, unsigned timeout_ms, const char *rd);

/* Replay a Mesa .rd capture (uncompressed): buffers at their iovas, then each command stream. */
int gpu_replay(const char *path, unsigned timeout_ms);
int gpu_vatest(int argc, char **argv);	/* which GPU VA ranges translate */
/* Panel scanout stride (both VIG pipes, then a CTL flush): 4320 as ABL left it, 4352 for the GPU. */
void panel_stride(uint32_t stride);

#endif
