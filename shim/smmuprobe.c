/*
 * SMMU probe mode (built with -DSHIM_SMMUPROBE): read-only dump of the apps
 * SMMU (MMU-500 at 0x15000000) as ABL leaves it, for the USB stream 0x140:
 * which SMR matches it, its S2CR, and the context bank's translation regime,
 * plus a walk of the bank's stage-1 tables for ABL's USB buffer and for
 * candidate DMA addresses.
 */
#ifdef SHIM_SMMUPROBE
#include <stdint.h>
#include "log.h"
#include "smmuprobe.h"
#include "util.h"

#define AS		0x15000000UL
#define SMR(n)		(AS + 0x800 + 4UL * (n))
#define S2CR(n)		(AS + 0xc00 + 4UL * (n))

static uint64_t rd64(uintptr_t a)
{
	return rd32(a) | ((uint64_t)rd32(a + 4) << 32);
}

static void walk(uintptr_t cb, uint64_t va)
{
	uint32_t tcr = rd32(cb + 0x30);
	uint64_t ttbr = rd64(cb + 0x20) & 0x0000fffffffff000ull;
	unsigned t0sz = tcr & 0x3f;
	int level = t0sz >= 25 ? 1 : 0;		/* 4K granule assumed */
	log_printf("smmu: walk va %lx tcr %x t0sz %u ttbr %lx\n", va, tcr, t0sz, ttbr);
	for (; level <= 3; level++) {
		unsigned shift = 39 - 9 * level;
		uint64_t idx = (va >> shift) & 0x1ff;
		uint64_t d = rd64(ttbr + 8 * idx);
		log_printf("  L%d [%lu] = %lx\n", level, idx, d);
		if (!(d & 1))
			return;
		if (level == 3 || !(d & 2))
			return;	/* page or block */
		ttbr = d & 0x0000fffffffff000ull;
	}
}

void smmuprobe_run(void)
{
	uint32_t idr0 = rd32(AS + 0x20), idr1 = rd32(AS + 0x24);
	unsigned nsmr = idr0 & 0xff, ncb = idr1 & 0xff;
	unsigned pagesz = (idr1 >> 31) ? 0x10000 : 0x1000;
	unsigned numpage = 1u << (((idr1 >> 28) & 7) + 1);
	uintptr_t cbbase = AS + (uintptr_t)numpage * pagesz;
	log_printf("smmu: apps cr0 %x idr0 %x idr1 %x nsmr %u ncb %u cbbase %lx\n", rd32(AS), idr0,
		   idr1, nsmr, ncb, (uint64_t)cbbase);
	for (unsigned i = 0; i < nsmr; i++) {
		uint32_t m = rd32(SMR(i));
		if (!(m >> 31))
			continue;
		uint32_t id = m & 0x7fff, mask = (m >> 16) & 0x7fff;
		int usb = ((0x140 ^ id) & ~mask & 0x7fff) == 0;
		uint32_t s = rd32(S2CR(i));
		if (usb || i < 4)
			log_printf("smmu: smr%u %x (id %x mask %x)%s s2cr %x type %u cb %u\n", i, m, id, mask,
				   usb ? " <- USB 0x140" : "", s, (s >> 16) & 3, s & 0xff);
		if (usb && ((s >> 16) & 3) == 0) {
			unsigned c = s & 0xff;
			uintptr_t cb = cbbase + (uintptr_t)c * pagesz;
			log_printf("smmu: cb%u cbar %x cba2r %x sctlr %x tcr %x tcr2 %x mair0 %x fsr %x far %lx\n",
				   c, rd32(AS + pagesz + 4 * c), rd32(AS + pagesz + 0x800 + 4 * c), rd32(cb),
				   rd32(cb + 0x30), rd32(cb + 0x10), rd32(cb + 0x38), rd32(cb + 0x58),
				   rd64(cb + 0x60));
			walk(cb, 0xfd34c000);
			walk(cb, 0xf0000000);
		}
	}
}
#endif /* SHIM_SMMUPROBE */
