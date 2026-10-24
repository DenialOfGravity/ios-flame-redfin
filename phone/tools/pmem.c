/*
 * pmem: 32-bit peek/poke of physical addresses (registers included) through /dev/pmem (boot-arg sweetpmem=1).
 *   pmem r PA [COUNT]     read COUNT words (default 1)
 *   pmem w PA VALUE       write one word, then read it back
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc < 3 || (strcmp(argv[1], "r") && strcmp(argv[1], "w")) || (!strcmp(argv[1], "w") && argc < 4)) {
		fprintf(stderr, "usage: pmem r PA [COUNT] | pmem w PA VALUE\n");
		return 2;
	}
	int fd = open("/dev/pmem", O_RDWR);
	if (fd < 0) {
		perror("/dev/pmem");
		return 1;
	}
	uint64_t pa = strtoull(argv[2], NULL, 0);
	if (!strcmp(argv[1], "w")) {
		uint32_t v = (uint32_t)strtoul(argv[3], NULL, 0);
		if (pwrite(fd, &v, 4, (off_t)pa) != 4) {
			perror("write");
			return 1;
		}
	}
	unsigned n = !strcmp(argv[1], "r") && argc > 3 ? (unsigned)strtoul(argv[3], NULL, 0) : 1;
	for (unsigned i = 0; i < n; i++) {
		uint32_t v;
		if (pread(fd, &v, 4, (off_t)(pa + 4ull * i)) != 4) {
			perror("read");
			return 1;
		}
		printf("%08llx: %08x\n", (unsigned long long)(pa + 4ull * i), v);
	}
	return 0;
}
