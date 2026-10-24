/*
 * imgdump: the code of a shared-cache library as it is in memory, for disassembly on the PC, and symbol lookups.
 *
 *   imgdump sym NAME...          dlsym(RTLD_DEFAULT) of each NAME (after loading the capture stack's frameworks),
 *                                printed as an unslid shared-cache address with its image
 *   imgdump text IMAGE OUT       the __TEXT,__text section of the loaded image whose path ends in IMAGE into OUT,
 *                                and its unslid address (llvm-objdump -D -b binary -m aarch64 --adjust-vma=ADDR)
 *   imgdump read ADDR LEN OUT    LEN bytes at the unslid shared-cache address ADDR into OUT
 *
 * Addresses are unslid (the shared cache's own, as pstack/a2s print them once the slide is taken off) so that
 * they are the same in every process and boot.
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CACHE_BASE 0x180000000UL

static const char *const libs[] = {
	"/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
	"/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
	"/System/Library/Frameworks/MediaToolbox.framework/MediaToolbox",
	"/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture",
	"/System/Library/PrivateFrameworks/Celestial.framework/Celestial",
	"/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience",
};

static uintptr_t
slide(void)
{
	const void *(*range)(size_t *) = (const void *(*)(size_t *))dlsym(RTLD_DEFAULT, "_dyld_get_shared_cache_range");
	size_t length = 0;

	return range ? (uintptr_t)range(&length) - CACHE_BASE : 0;
}

static int
write_out(const char *path, const void *p, size_t n)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd < 0 || write(fd, p, n) != (ssize_t)n) {
		perror(path);
		return 1;
	}
	close(fd);
	return 0;
}

int
main(int argc, char **argv)
{
	uintptr_t s;

	for (size_t i = 0; i < sizeof(libs) / sizeof(libs[0]); i++) {
		(void)dlopen(libs[i], RTLD_LAZY);
	}
	s = slide();
	if (argc >= 3 && strcmp(argv[1], "sym") == 0) {
		for (int i = 2; i < argc; i++) {
			void *p = dlsym(RTLD_DEFAULT, argv[i]);
			Dl_info di;

			if (p == NULL) {
				printf("%s: none\n", argv[i]);
			} else if (dladdr(p, &di)) {
				printf("%s: %#lx %s\n", argv[i], (uintptr_t)p - s, di.dli_fname);
			}
		}
		return 0;
	}
	if (argc == 4 && strcmp(argv[1], "text") == 0) {
		for (uint32_t i = 0; i < _dyld_image_count(); i++) {
			const char *name = _dyld_get_image_name(i);
			size_t n = strlen(name), m = strlen(argv[2]);

			if (n < m || strcmp(name + n - m, argv[2]) != 0) {
				continue;
			}
			const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
			const struct load_command *lc = (const struct load_command *)(h + 1);

			for (uint32_t c = 0; c < h->ncmds; c++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
				if (lc->cmd != LC_SEGMENT_64) {
					continue;
				}
				const struct segment_command_64 *seg = (const void *)lc;
				const struct section_64 *sect = (const void *)(seg + 1);

				for (uint32_t k = 0; k < seg->nsects; k++) {
					if (strcmp(sect[k].segname, "__TEXT") == 0 && strcmp(sect[k].sectname, "__text") == 0) {
						uintptr_t at = sect[k].addr + _dyld_get_image_vmaddr_slide(i);

						printf("%s: __text at %#lx, %#llx bytes\n", name, at - s, (unsigned long long)sect[k].size);
						return write_out(argv[3], (const void *)at, sect[k].size);
					}
				}
			}
		}
		printf("no loaded image ends in %s\n", argv[2]);
		return 1;
	}
	if (argc == 5 && strcmp(argv[1], "read") == 0) {
		uintptr_t a = strtoul(argv[2], NULL, 16) + s;
		size_t n = strtoul(argv[3], NULL, 0);

		return write_out(argv[4], (const void *)a, n);
	}
	fprintf(stderr, "usage: imgdump sym NAME... | text IMAGE OUT | read ADDR LEN OUT\n");
	return 2;
}
