#include <string.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include "sweetgpu.h"

int sg_open(struct sg_dev *d, io_service_t service)
{
	memset(d, 0, sizeof(*d));
	io_service_t s = service ? service :
	    IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("SweetAccelerator"));
	if (!s)
		return -1;
	kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &d->conn);
	if (!service)
		IOObjectRelease(s);
	if (kr != KERN_SUCCESS)
		return -1;
	uint64_t out[3] = { 0 };
	uint32_t n = 3;
	if (IOConnectCallScalarMethod(d->conn, 0, NULL, 0, out, &n) != KERN_SUCCESS || !out[2]) {
		IOServiceClose(d->conn);
		return -1;		/* GPU not up (boot-arg sweetgpu=1) */
	}
	d->gpu_id = (uint32_t)out[0];
	d->chip_id = out[1];
	return 0;
}

void sg_close(struct sg_dev *d)
{
	if (d->conn)
		IOServiceClose(d->conn);
	d->conn = 0;
}

int sg_bo_alloc(struct sg_dev *d, uint64_t size, struct sg_bo *bo)
{
	uint64_t in[1] = { size }, out[3] = { 0 };
	uint32_t n = 3;
	memset(bo, 0, sizeof(*bo));
	if (IOConnectCallScalarMethod(d->conn, 1, in, 1, out, &n) != KERN_SUCCESS)
		return -1;
	bo->handle = out[0];
	bo->va = out[1];
	bo->size = out[2];
	mach_vm_address_t addr = 0;
	mach_vm_size_t len = 0;
	if (IOConnectMapMemory64(d->conn, (uint32_t)bo->handle, mach_task_self(), &addr, &len,
				 kIOMapAnywhere | kIOMapDefaultCache) != KERN_SUCCESS) {
		sg_bo_free(d, bo);
		return -1;
	}
	bo->map = (void *)(uintptr_t)addr;
	return 0;
}

/* the last 256 buffers freed (GPU VA, size): dumped when a submit fails, to match the fault address */
static struct { uint64_t va, size; } freelog[256];
static unsigned freelog_n;

void sweet_free_log_dump(void)
{
	int fd = open("/var/local/mtl.log", O_WRONLY | O_APPEND);
	if (fd < 0)
		return;
	dprintf(fd, "MTL[%d]: gpu: last %u buffers freed (va+size, oldest first):\n", getpid(), freelog_n < 256 ? freelog_n : 256);
	for (unsigned i = freelog_n < 256 ? 0 : freelog_n - 256, k = 0; i < freelog_n; i++, k++)
		dprintf(fd, "%s%llx+%llx%s", k % 8 ? " " : "  ", (unsigned long long)freelog[i % 256].va,
			(unsigned long long)freelog[i % 256].size, k % 8 == 7 || i + 1 == freelog_n ? "\n" : "");
	close(fd);
}

int sg_bo_free(struct sg_dev *d, struct sg_bo *bo)
{
	freelog[freelog_n % 256].va = bo->va;
	freelog[freelog_n % 256].size = bo->size;
	freelog_n++;
	if (bo->map)
		IOConnectUnmapMemory64(d->conn, (uint32_t)bo->handle, mach_task_self(),
				       (mach_vm_address_t)(uintptr_t)bo->map);
	uint64_t in[1] = { bo->handle };
	kern_return_t kr = IOConnectCallScalarMethod(d->conn, 2, in, 1, NULL, NULL);
	memset(bo, 0, sizeof(*bo));
	return kr == KERN_SUCCESS ? 0 : -1;
}

int sg_surface_import(struct sg_dev *d, uint32_t surface_id, struct sg_bo *bo)
{
	uint64_t in[1] = { surface_id }, out[3] = { 0 };
	uint32_t n = 3;
	memset(bo, 0, sizeof(*bo));
	if (IOConnectCallScalarMethod(d->conn, 3, in, 1, out, &n) != KERN_SUCCESS)
		return -1;
	bo->handle = out[0];
	bo->va = out[1];
	bo->size = out[2];
	return 0;
}

int sg_submit_async(struct sg_dev *d, uint64_t ib_va, uint32_t dwords, uint32_t *fence)
{
	uint64_t in[2] = { ib_va, dwords }, out[1] = { 0 };
	uint32_t n = 1;
	kern_return_t kr = IOConnectCallScalarMethod(d->conn, 6, in, 2, out, &n);
	*fence = (uint32_t)out[0];
	return kr == KERN_SUCCESS && *fence ? 0 : -1;
}

int sg_wait_fence(struct sg_dev *d, uint32_t fence, uint32_t timeout_ms)
{
	uint64_t in[2] = { fence, timeout_ms };
	return IOConnectCallScalarMethod(d->conn, 7, in, 2, NULL, NULL) == KERN_SUCCESS ? 0 : -1;
}

int sg_submit(struct sg_dev *d, uint64_t ib_va, uint32_t dwords, uint32_t timeout_ms, uint32_t *fence)
{
	uint64_t in[3] = { ib_va, dwords, timeout_ms }, out[1] = { 0 };
	uint32_t n = 1;
	kern_return_t kr = IOConnectCallScalarMethod(d->conn, 4, in, 3, out, &n);
	if (fence)
		*fence = (uint32_t)out[0];
	return kr == KERN_SUCCESS ? 0 : -1;
}

static uint32_t parity(uint32_t v)
{
	return (0x9669 >> (0xf & (v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^ (v >> 20) ^ (v >> 24) ^
				  (v >> 28)))) & 1;
}

uint32_t sg_pkt7(uint32_t op, uint32_t cnt)
{
	return 0x70000000 | cnt | (parity(cnt) << 15) | ((op & 0x7f) << 16) | (parity(op) << 23);
}

uint32_t sg_pkt4(uint32_t reg, uint32_t cnt)
{
	return 0x40000000 | cnt | (parity(cnt) << 7) | ((reg & 0x3ffff) << 8) | (parity(reg) << 27);
}

/*
 * The GPU does not snoop the CPU caches: clean+invalidate part of a buffer,
 * in the kernel (sys_dcache_flush does nothing on iOS).
 */
int sg_cache_flush(struct sg_dev *d, const struct sg_bo *bo, uint64_t offset, uint64_t len)
{
	uint64_t in[3] = { bo->handle, offset, len };
	return IOConnectCallScalarMethod(d->conn, 5, in, 3, NULL, NULL) == KERN_SUCCESS ? 0 : -1;
}
