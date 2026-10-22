#include <stdio.h>
#include <string.h>
#include <time.h>
#include "ath.h"
#include "pmem.h"

#define WCSS		0x18800000ull
#define CE_BASE(i)	(WCSS + 0x240000 + 0x1000ull * (i))
#define CE_RRI_LO	(WCSS + 0x24c004)
#define CE_RRI_HI	(WCSS + 0x24c008)
#define SHADOW_SR(i)	(WCSS + 0x32000 + 4ull * (i))	/* ce 0, 3, 4, 5, 7 */

/* wcn3990_ce_regs */
#define SR_BASE_LO	0x00
#define SR_BASE_HI	0x04
#define SR_SIZE		0x08
#define DR_BASE_LO	0x0c
#define DR_BASE_HI	0x10
#define DR_SIZE		0x14
#define CTRL1		0x18
#define DST_WR_INDEX	0x40
#define SRC_WM		0x4c
#define DST_WM		0x50

#define NCE		12
#define BUF_SZ		2048
#define DESC		16

/* host_ce_config_wlan, with smaller rings (we poll, and never stream data yet) */
static const struct { unsigned src, src_max, dst; } cfg[NCE] = {
	{ 16, 2048, 0 }, { 0, 2048, 32 }, { 0, 2048, 64 }, { 32, 2048, 0 }, { 32, 256, 0 }, { 0, 512, 32 },
	{ 0, 0, 0 },     { 2, 2048, 2 },  { 0, 2048, 32 }, { 0, 2048, 32 }, { 0, 2048, 32 }, { 0, 2048, 32 },
};

static struct ring {
	unsigned n, wi, ri;		/* entries; our write index; our read (completion) index */
	uint64_t desc, buf;		/* PA of the descriptors and of n buffers of BUF_SZ */
} src[NCE], dst[NCE];

static uint64_t mem, mem_end, mem_next, rri;
static htc_rx_cb_t rx_cb;
int ath_wmi_eid = -1, ath_htt_eid = -1;
static int ready, credits, credit_size;
static uint8_t ctl_resp[64];
static int ctl_resp_len;

static uint64_t carve(uint64_t size)
{
	uint64_t p = (mem_next + 63) & ~63ull;
	mem_next = p + size;
	return mem_next <= mem_end ? p : 0;