#pragma once
#include <stdint.h>

/* What XNU gets as Boot_Video (the scanned-out splash buffer). */
struct loader_fb {
	uint64_t base, stride, width, height;
	void (*before_jump)(void);	/* last chance to save the log */
};

int loader_has_payload(uintptr_t dtb);

/* Boot the SWEETXNU payload found in the ABL ramdisk; returns only on error. */
const char *loader_boot(uintptr_t dtb, const struct loader_fb *fb);
