/*
 * mtlk: test the kernel GPU interface Metal will use (no Metal involved).
 * Allocates an IB and a target buffer, writes CP_MEM_WRITE from the CPU,
 * submits, checks the GPU's write through the CPU mapping; then a 64 MB
 * buffer filled by CP_MEMCPY to check large mappings.
 *   mtlk fault: first a write to an unmapped GPU VA (SMMU fault: the kernel recovers the GPU), then the tests.
 */
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "sweetgpu.h"

int main(int argc, char **argv)
{
	struct sg_dev d;
	if (sg_open(&d, 0)) {
		fprintf(stderr, "mtlk: no SweetAccelerator (boot-args sweetgpu=1 sweetmtl=1)\n");
		return 1;
	}
	printf("gpu %u chip %llx\n", d.gpu_id, (unsigned long long)d.chip_id);
	struct sg_bo ib, dst;
	if (sg_bo_alloc(&d, 4096, &ib) || sg_bo_alloc(&d, 4096, &dst)) {
		fprintf(stderr, "alloc failed\n");
		return 1;
	}
	printf("ib va %llx map %p, dst va %llx map %p\n", (unsigned long long)ib.va, ib.map,
	       (unsigned long long)dst.va, dst.map);
	uint32_t *w = ib.map, n = 0;
	if (argc > 1 && !strcmp(argv[1], "fault")) {
		w[0] = sg_pkt7(0x3d, 3);	/* CP_MEM_WRITE to 0x30000000: nothing mapped there */
		w[1] = 0x30000000;
		w[2] = 0;
		w[3] = 0xdead;
		sg_cache_flush(&d, &ib, 0, 4096);
		uint32_t f = 0;
		printf("fault submit -> %d (expected to fail; the kernel recovers the GPU)\n", sg_submit(&d, ib.va, 4, 500, &f));
	}
	w[n++] = sg_pkt7(0x3d, 3);		/* CP_MEM_WRITE */
	w[n++] = (uint32_t)dst.va;
	w[n++] = (uint32_t)(dst.va >> 32);
	w[n++] = 0x600dc0de;
	sg_cache_flush(&d, &ib, 0, 4096);
	sg_cache_flush(&d, &dst, 0, 4096);
	uint32_t fence = 0;
	struct timespec t0, t1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	int rc = sg_submit(&d, ib.va, n, 1000, &fence);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	sg_cache_flush(&d, &dst, 0, 4096);
	printf("submit -> %d fence %u in %.3f ms; dst[0] = %08x %s\n", rc, fence,
	       (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6, ((volatile uint32_t *)dst.map)[0],
	       ((volatile uint32_t *)dst.map)[0] == 0x600dc0de ? "OK" : "WRONG");

	struct sg_bo big;
	if (sg_bo_alloc(&d, 64 << 20, &big)) {
		fprintf(stderr, "64 MB alloc failed\n");
		return 1;
	}
	n = 0;
	for (uint64_t off = 0; off < big.size; off += 1 << 20) {	/* the first word of each MB */
		uint64_t a = big.va + off;
		w[n++] = sg_pkt7(0x3d, 3);
		w[n++] = (uint32_t)a;
		w[n++] = (uint32_t)(a >> 32);
		w[n++] = 0xb16b0000u | (uint32_t)(off >> 20);
	}
	sg_cache_flush(&d, &ib, 0, 4096);
	sg_cache_flush(&d, &big, 0, big.size);
	rc = sg_submit(&d, ib.va, n, 1000, &fence);
	sg_cache_flush(&d, &big, 0, big.size);
	int bad = 0;
	for (uint64_t off = 0; off < big.size; off += 1 << 20)
		bad += ((volatile uint32_t *)big.map)[off / 4] != (0xb16b0000u | (uint32_t)(off >> 20));
	printf("64 MB buffer at va %llx: submit -> %d, %d of 64 words wrong\n", (unsigned long long)big.va, rc, bad);
	sg_close(&d);
	return rc || bad;
}
