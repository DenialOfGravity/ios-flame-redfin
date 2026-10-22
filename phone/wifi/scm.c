/* Secure-world calls shared by the services (Linux qcom_scm_assign_mem / downstream hyp_assign_phys). */
#include <stdio.h>
#include "pmem.h"
#include "scm.h"

int hyp_assign(uint64_t pa, uint64_t size, const uint32_t *src, int nsrc, const uint32_t *dst, int ndst)
{
	uint64_t t = pm_alloc(4096, 4096);
	if (!t || nsrc > 8 || ndst > 8)
		return -1;
	uint64_t mem[2] = { pa, size };
	struct { uint32_t vm, perm; uint64_t ctx; uint32_t ctx_size, pad; } d[8] = { { 0 } };
	for (int i = 0; i < ndst; i++) {
		d[i].vm = dst[i];
		d[i].perm = 6;					/* read | write */
	}
	uint64_t ext[4] = { 4ull * nsrc, t + 128, sizeof(d[0]) * ndst, 0 };
	pm_wr(t, mem, sizeof(mem));
	pm_wr(t + 64, src, 4ull * nsrc);
	pm_wr(t + 128, d, sizeof(d[0]) * ndst);
	pm_wr(t + 512, ext, sizeof(ext));
	/* MP_ASSIGN (0x0c/0x16): SCM_ARGS(7, RO, VAL, RO, VAL, RO, VAL, VAL); args 3.. go through x5 */
	uint64_t x[8] = { 0x42000000ull | (0xcu << 8) | 0x16, 7 | (1u << 4) | (1u << 8) | (1u << 12),
			  t, sizeof(mem), t + 64, t + 512, 0, 0 };
	pm_smc(x);
	pm_free(t);
	printf("scm: hyp_assign %llx+%llx to %d vm(s) -> %lld\n", (unsigned long long)pa, (unsigned long long)size, ndst,
	       (long long)x[0]);
	return x[0] ? -1 : 0;
}
