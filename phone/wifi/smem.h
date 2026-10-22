/* SMEM (Qualcomm shared memory) from userland, after Linux drivers/soc/qcom/smem.c. */
#ifndef SMEM_H
#define SMEM_H
#include <stdint.h>

#define SMEM_BASE	0x86000000ull	/* smem_mem, sm8150 */
#define SMEM_SIZE	0x200000ull
#define SMEM_HOST_APPS	0
#define SMEM_HOST_MODEM	1
#define SMEM_HOST_GLOBAL 0xfffe

int smem_init(void);
/* Item in the partition shared with host (or the global area): PA and size, 0 = found. */
int smem_get(unsigned host, unsigned item, uint64_t *pa, uint32_t *size);
/* Allocate (if missing) an item in the partition shared with host; returns its PA. */
int smem_alloc(unsigned host, unsigned item, uint32_t size, uint64_t *pa);
void smem_dump(void);
void smem_list(void);		/* item numbers in the apps-shared and global partitions */

#endif
