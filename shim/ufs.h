#pragma once
#include <stdint.h>

/*
 * Scratch area at the end of userdata, in 4K blocks. The last 1025 blocks
 * belong to the XNU persistent console log (ring + header); the shim's log
 * goes in the 64 blocks before them, and the RAM log rescue (ramlog.c) in
 * the 64 blocks before that.
 */
#define UFS_XNU_LOG_BLOCKS	1025u
#define UFS_SCRATCH_BLOCKS	64u
#define UFS_SCRATCH_TAIL	(UFS_XNU_LOG_BLOCKS + UFS_SCRATCH_BLOCKS)
#define UFS_RESCUE_BLOCKS	64u

int ufs_init(void);
int ufs_scratch_read(uint32_t idx, uint32_t count, void *buf);
int ufs_scratch_write(uint32_t idx, uint32_t count, const void *buf);
int ufs_rescue_write(uint32_t idx, uint32_t count, const void *buf);
