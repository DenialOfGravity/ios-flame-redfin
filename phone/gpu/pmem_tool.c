/*
 * pmem: physical memory from the shell (on the phone, as root).
 *
 *   pmem r PA [N]            read N 32-bit words (default 1)
 *   pmem w PA VAL            write a word, print the read-back
 *   pmem m PA MASK VAL       read-modify-write
 *   pmem dump PA LEN         raw bytes to stdout (LEN multiple of 4)
 *   pmem load PA FILE        file contents to PA
 *   pmem alloc SIZE [ALIGN]  contiguous DMA memory; prints its PA
 *   pmem free PA
 *   pmem list                live allocations
 *   pmem smc X0 [X1..X7]     SMCCC call, prints x0..x3
 *
 * Numbers: 0x.. hex, else decimal.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "pmem.h"

static uint64_t num(const char *s)
{
	return strtoull(s, NULL, 0);
}

static int usage(void)
{
	fprintf(stderr, "usage: pmem r PA [N] | w PA VAL | m PA MASK VAL | dump PA LEN | load PA FILE |\n"
			"            alloc SIZE [ALIGN] | free PA | list | smc X0 [X1..X7]\n");
	return 2;
}

int main(int argc, char **argv)
{
	if (argc < 2)
		return usage();
	pm_init();
	const char *c = argv[1];
	if (!strcmp(c, "r") && argc >= 3) {
		uint64_t pa = num(argv[2]), n = argc > 3 ? num(argv[3]) : 1;
		for (uint64_t i = 0; i < n; i += 4) {
			printf("%09llx:", (unsigned long long)(pa + 4 * i));
			for (uint64_t j = i; j < n && j < i + 4; j++)
				printf(" %08x", rd32(pa + 4 * j));
			printf("\n");
		}
	} else if (!strcmp(c, "w") && argc >= 4) {
		uint64_t pa = num(argv[2]);
		wr32(pa, (uint32_t)num(argv[3]));
		printf("%09llx = %08x\n", (unsigned long long)pa, rd32(pa));
	} else if (!strcmp(c, "m") && argc >= 5) {
		uint64_t pa = num(argv[2]);
		uint32_t mask = (uint32_t)num(argv[3]), v = (uint32_t)num(argv[4]), old = rd32(pa);
		wr32(pa, (old & ~mask) | (v & mask));
		printf("%09llx %08x -> %08x\n", (unsigned long long)pa, old, rd32(pa));
	} else if (!strcmp(c, "dump") && argc >= 4) {
		uint64_t pa = num(argv[2]), len = num(argv[3]);
		static char buf[1 << 16];
		for (uint64_t o = 0; o < len;) {
			size_t n = len - o < sizeof(buf) ? (size_t)(len - o) : sizeof(buf);
			if (pm_rd(pa + o, buf, n) || fwrite(buf, 1, n, stdout) != n)
				return 1;
			o += n;
		}
	} else if (!strcmp(c, "load") && argc >= 4) {
		FILE *f = fopen(argv[3], "rb");
		if (!f) {
			perror(argv[3]);
			return 1;
		}
		static char buf[1 << 16];
		uint64_t pa = num(argv[2]), o = 0;
		size_t n;
		while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
			if (pm_wr(pa + o, buf, n))
				return 1;
			o += n;
		}
		printf("%llu bytes at %09llx\n", (unsigned long long)o, (unsigned long long)pa);
	} else if (!strcmp(c, "alloc") && argc >= 3) {
		uint64_t pa = pm_alloc(num(argv[2]), argc > 3 ? num(argv[3]) : 0);
		if (!pa)
			return 1;
		printf("0x%llx\n", (unsigned long long)pa);
	} else if (!strcmp(c, "free") && argc >= 3) {
		if (pm_free(num(argv[2]))) {
			perror("free");
			return 1;
		}
	} else if (!strcmp(c, "list")) {
		struct pmem_list l;
		if (pm_list(&l))
			return 1;
		for (uint32_t i = 0; i < l.count; i++)
			printf("0x%09llx %llu\n", (unsigned long long)l.ent[i].pa,
			       (unsigned long long)l.ent[i].size);
	} else if (!strcmp(c, "smc") && argc >= 3) {
		uint64_t x[8] = { 0 };
		for (int i = 0; i < 8 && i + 2 < argc; i++)
			x[i] = num(argv[i + 2]);
		pm_smc(x);
		printf("x0 %llx x1 %llx x2 %llx x3 %llx\n", (unsigned long long)x[0],
		       (unsigned long long)x[1], (unsigned long long)x[2], (unsigned long long)x[3]);
	} else {
		return usage();
	}
	return 0;
}
