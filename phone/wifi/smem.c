/*
 * SMEM from userland: the region is a carve-out (device mapping through
 * /dev/pmem, 32-bit accesses). Layout per Linux drivers/soc/qcom/smem.c:
 * header with a global table of contents, and (v12) a partition table
 * "$TOC" in the last 4 KB with one partition per host pair, holding
 * uncached entries growing up and cached entries growing down.
 * Allocation takes TCSR hardware mutex 3, as Linux does.
 */
#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include "pmem.h"
#include "smem.h"

#define TCSR_MUTEX(n)	(0x1f40000ull + 0x1000ull * (n))
#define SMEM_HWLOCK	3
#define APPS_PROC_ID	1

#define PTABLE		(SMEM_BASE + SMEM_SIZE - 0x1000)
#define CANARY		0xa5a5

static struct part {
	uint64_t pa;
	uint32_t size, cacheline;
	uint16_t host0, host1;
} parts[32];
static unsigned nparts;
static int global_part = -1;

static uint16_t rd16(uint64_t pa)
{
	uint32_t w = rd32(pa & ~3ull);
	return (uint16_t)(w >> (8 * (pa & 2)));
}

int smem_init(void)
{
	pm_init();
	if (rd32(PTABLE) != 0x434f5424) {	/* "$TOC" */
		fprintf(stderr, "smem: no partition table (%08x)\n", rd32(PTABLE));
		return -1;
	}
	uint32_t n = rd32(PTABLE + 8);
	for (uint32_t i = 0; i < n && nparts < 32; i++) {
		uint64_t e = PTABLE + 32 + 48ull * i;
		uint32_t off = rd32(e), size = rd32(e + 4);
		uint32_t hosts = rd32(e + 12);
		if (!off || !size)
			continue;
		uint16_t h0 = (uint16_t)hosts, h1 = (uint16_t)(hosts >> 16);
		/*
		 * Only partitions the apps CPU is part of (or the global one): the
		 * others (e.g. ADSP-SLPI) are access-protected from here, and reading
		 * them stalls the bus for good.
		 */
		bool global = h0 == SMEM_HOST_GLOBAL && h1 == SMEM_HOST_GLOBAL;
		if (!global && h0 != SMEM_HOST_APPS && h1 != SMEM_HOST_APPS)
			continue;
		struct part *p = &parts[nparts];
		p->pa = SMEM_BASE + off;
		p->size = size;
		p->host0 = h0;
		p->host1 = h1;
		p->cacheline = rd32(e + 16);
		if (rd32(p->pa) != 0x54525024)	/* "$PRT" */
			fprintf(stderr, "smem: partition %u bad magic\n", i);
		if (p->host0 == SMEM_HOST_GLOBAL && p->host1 == SMEM_HOST_GLOBAL)
			global_part = (int)nparts;
		nparts++;
	}
	return 0;
}

static struct part *find_part(unsigned host)
{
	if (host == SMEM_HOST_GLOBAL)
		return global_part >= 0 ? &parts[global_part] : NULL;
	for (unsigned i = 0; i < nparts; i++)
		if ((parts[i].host0 == SMEM_HOST_APPS && parts[i].host1 == host) ||
		    (parts[i].host1 == SMEM_HOST_APPS && parts[i].host0 == host))
			return &parts[i];
	return NULL;
}

static int part_get(struct part *p, unsigned item, uint64_t *pa, uint32_t *size)
{
	uint32_t free_unc = rd32(p->pa + 12), free_cac = rd32(p->pa + 16);
	/* uncached: from the header up */
	for (uint64_t e = p->pa + 32; e < p->pa + free_unc;) {
		if (rd16(e) != CANARY)
			return -2;
		uint16_t it = rd16(e + 2);
		uint32_t sz = rd32(e + 4);
		uint16_t pad_data = rd16(e + 8), pad_hdr = rd16(e + 10);
		if (it == item) {
			*pa = e + 16 + pad_hdr;
			*size = sz - pad_data;
			return 0;
		}
		e += 16 + pad_hdr + sz;
	}
	/* cached: from the end down */
	uint32_t cl = p->cacheline ? p->cacheline : 64;
	for (uint64_t e = p->pa + p->size - ((16 + cl - 1) & ~(cl - 1)); e > p->pa + free_cac;) {
		if (rd16(e) != CANARY)
			return -2;
		uint16_t it = rd16(e + 2);
		uint32_t sz = rd32(e + 4);
		if (it == item) {
			*pa = e - sz;
			*size = sz - rd16(e + 8);
			return 0;
		}
		e -= sz + ((16 + cl - 1) & ~(cl - 1));
	}
	return -1;
}

int smem_get(unsigned host, unsigned item, uint64_t *pa, uint32_t *size)
{
	struct part *p = find_part(host);
	if (p && part_get(p, item, pa, size) == 0)
		return 0;
	if (global_part >= 0 && part_get(&parts[global_part], item, pa, size) == 0)
		return 0;
	/* legacy global table of contents */
	uint64_t toc = SMEM_BASE + 16 * 4 + 32 * 4 + 16 + 16ull * item;
	if (item < 512 && rd32(toc)) {
		*pa = SMEM_BASE + rd32(toc + 4);
		*size = rd32(toc + 8);
		return 0;
	}
	return -1;
}

static int hwlock(void)
{
	for (int i = 0; i < 100000; i++) {
		wr32(TCSR_MUTEX(SMEM_HWLOCK), APPS_PROC_ID);
		if (rd32(TCSR_MUTEX(SMEM_HWLOCK)) == APPS_PROC_ID)
			return 0;
	}
	return -1;
}

static void hwunlock(void)
{
	wr32(TCSR_MUTEX(SMEM_HWLOCK), 0);
}

int smem_alloc(unsigned host, unsigned item, uint32_t size, uint64_t *pa)
{
	uint32_t got;
	if (smem_get(host, item, pa, &got) == 0)
		return 0;
	struct part *p = find_part(host);
	if (!p || hwlock())
		return -1;
	uint32_t free_unc = rd32(p->pa + 12), free_cac = rd32(p->pa + 16);
	uint32_t asize = (size + 7) & ~7u;
	if (free_unc + 16 + asize > free_cac) {
		hwunlock();
		return -1;
	}
	uint64_t e = p->pa + free_unc;
	wr32(e, CANARY | ((uint32_t)item << 16));
	wr32(e + 4, asize);
	wr32(e + 8, (asize - size) | (0u << 16));	/* padding_data, padding_hdr */
	wr32(e + 12, 0);
	for (uint32_t o = 0; o < asize; o += 4)
		wr32(e + 16 + o, 0);
	__asm__ volatile("dsb sy" ::: "memory");
	wr32(p->pa + 12, free_unc + 16 + asize);
	hwunlock();
	*pa = e + 16;
	return 0;
}

void smem_dump(void)
{
	printf("smem: %u partitions, global %d\n", nparts, global_part);
	for (unsigned i = 0; i < nparts; i++) {
		struct part *p = &parts[i];
		printf(" part %u: hosts %u-%u pa %llx size %x cacheline %u free unc %x cac %x\n", i, p->host0,
		       p->host1, (unsigned long long)p->pa, p->size, p->cacheline, rd32(p->pa + 12), rd32(p->pa + 16));
	}
	static const unsigned items[] = { 137, 421, 427, 428, 429, 430, 432, 435, 443, 478, 479, 480, 481 };
	for (unsigned i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
		uint64_t pa;
		uint32_t sz;
		if (smem_get(SMEM_HOST_MODEM, items[i], &pa, &sz) == 0)
			printf(" item %u: pa %llx size %u\n", items[i], (unsigned long long)pa, sz);
	}
}

void smem_list(void)
{
	for (unsigned i = 0; i < nparts; i++) {
		struct part *p = &parts[i];
		if (p->host0 != SMEM_HOST_APPS && p->host0 != SMEM_HOST_GLOBAL)
			continue;	/* other hosts' partitions stall the bus */
		uint32_t free_unc = rd32(p->pa + 12), free_cac = rd32(p->pa + 16);
		printf("part %u (hosts %u-%u):", i, p->host0, p->host1);
		for (uint64_t e = p->pa + 32; e < p->pa + free_unc;) {
			if (rd16(e) != CANARY) {
				printf(" [bad canary at %llx]", (unsigned long long)e);
				break;
			}
			printf(" %u", rd16(e + 2));
			e += 16 + rd16(e + 10) + rd32(e + 4);
		}
		printf(" | cached:");
		uint32_t cl = p->cacheline ? p->cacheline : 64;
		for (uint64_t e = p->pa + p->size - ((16 + cl - 1) & ~(cl - 1)); e > p->pa + free_cac;) {
			if (rd16(e) != CANARY)
				break;
			printf(" %u", rd16(e + 2));
			e -= rd32(e + 4) + ((16 + cl - 1) & ~(cl - 1));
		}
		printf("\n");
	}
}
