/*
 * Userland side of the kernel's SweetAccelerator user client
 * (iokit/Kernel/arm/SweetAccelerator.cpp): GPU buffers mapped into this
 * process (write-combined), IOSurface import, IB submission.
 */
#ifndef SWEETGPU_H
#define SWEETGPU_H
#include <stddef.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

struct sg_dev {
	io_connect_t conn;
	uint32_t gpu_id;
	uint64_t chip_id;
};

struct sg_bo {
	uint64_t handle, va, size;
	void *map;		/* CPU mapping (cacheable: see sg_cache_flush), or NULL for imported surfaces */
};

int sg_open(struct sg_dev *d, io_service_t service);	/* service 0: find SweetAccelerator */
void sg_close(struct sg_dev *d);
int sg_bo_alloc(struct sg_dev *d, uint64_t size, struct sg_bo *bo);
void sweet_free_log_dump(void);	/* to /var/local/mtl.log */
int sg_bo_free(struct sg_dev *d, struct sg_bo *bo);
int sg_surface_import(struct sg_dev *d, uint32_t surface_id, struct sg_bo *bo);
int sg_submit_async(struct sg_dev *d, uint64_t ib_va, uint32_t dwords, uint32_t *fence);	/* queued, no wait */
int sg_wait_fence(struct sg_dev *d, uint32_t fence, uint32_t timeout_ms);	/* 0, or -1 on timeout */
int sg_submit(struct sg_dev *d, uint64_t ib_va, uint32_t dwords, uint32_t timeout_ms, uint32_t *fence);

/* Before a submit, for what the CPU wrote; after it, for what the CPU will read. */
int sg_cache_flush(struct sg_dev *d, const struct sg_bo *bo, uint64_t offset, uint64_t len);

/* PM4 */
uint32_t sg_pkt7(uint32_t op, uint32_t cnt);
uint32_t sg_pkt4(uint32_t reg, uint32_t cnt);

#endif
