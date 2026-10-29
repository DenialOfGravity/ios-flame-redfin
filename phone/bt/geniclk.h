/*
 * gcc-lito.c ftbl_gcc_qupv3_wrap0_s0_clk_src (shared by every wrap0 SE clock source) and the choice of
 * source rate + GENI divider for a UART speed, as qcom_geni_serial.c get_clk_div_rate does: the lowest
 * table rate that divides to baud x oversampling within 2 %. CX corner limits of the RCG (rate_max):
 * <= 75 MHz LOWER, <= 100 MHz LOW, <= 128 MHz NOMINAL: 3 Mbaud x 32 = 96 MHz stays at LOW, 3.2 Mbaud x 32
 * = 102.4 MHz needs NOMINAL (we cast no CX vote, so it is not the default).
 * Parents (gcc_parent_map_0): 0 = XO 19.2 MHz, 1 = GPLL0 600 MHz, 6 = GPLL0_OUT_EVEN 300 MHz.
 * hid = 2 * pre_div - 1 (CFG_RCGR [4:0]); M/N in dual-edge mode when n != 0.
 */
#ifndef BT_GENICLK_H
#define BT_GENICLK_H
#include <stdint.h>

struct geniclk_row {
	uint32_t rate;
	uint8_t src, hid;
	uint16_t m, n;
};

static const struct geniclk_row geniclk_rows[] = {
	{ 7372800, 6, 1, 384, 15625 }, { 14745600, 6, 1, 768, 15625 }, { 19200000, 0, 1, 0, 0 },
	{ 29491200, 6, 1, 1536, 15625 }, { 32000000, 6, 1, 8, 75 }, { 48000000, 6, 1, 4, 25 },
	{ 50000000, 6, 11, 0, 0 }, { 64000000, 6, 1, 16, 75 }, { 75000000, 6, 7, 0, 0 },
	{ 80000000, 6, 1, 4, 15 }, { 96000000, 6, 1, 8, 25 }, { 100000000, 1, 11, 0, 0 },
	{ 102400000, 6, 1, 128, 375 }, { 112000000, 6, 1, 28, 75 }, { 117964800, 6, 1, 6144, 15625 },
	{ 120000000, 6, 4, 0, 0 }, { 128000000, 1, 1, 16, 75 },
};

static inline int geniclk_fits(uint32_t rate, uint32_t desired, unsigned *div)
{
	if (!desired || rate < desired - desired / 50)
		return 0;
	unsigned d = (rate + desired / 2) / desired;
	if (d < 1 || d > 4095)
		return 0;
	uint32_t got = rate / d;
	uint32_t tol = desired / 50;
	if (got + tol < desired || got > desired + tol)
		return 0;
	*div = d;
	return 1;
}

static inline const struct geniclk_row *geniclk_pick(uint32_t desired, unsigned *div)
{
	for (unsigned i = 0; i < sizeof(geniclk_rows) / sizeof(geniclk_rows[0]); i++)
		if (geniclk_fits(geniclk_rows[i].rate, desired, div))
			return &geniclk_rows[i];
	return 0;
}

/* a DFS level's rate from its SE_PERF_DFSR / M / N registers (clk-rcg2.c clk_rcg2_dfs_populate_freq) */
static inline uint32_t geniclk_dfs_rate(uint32_t cfg, uint32_t m, uint32_t nreg)
{
	unsigned src = (cfg >> 8) & 7, hid = cfg & 0x1f;
	uint64_t parent = src == 0 ? 19200000u : src == 1 ? 600000000u : src == 6 ? 300000000u : 0;
	uint64_t rate = hid ? parent * 2 / (hid + 1) : parent;
	if (((cfg >> 12) & 3) == 2) {
		m &= 0xffff;
		uint32_t n = ((~nreg) & 0xffff) + m;
		if (n)
			rate = rate * m / n;
	}
	return (uint32_t)rate;
}

static inline int geniclk_pick_dfs(const uint32_t *rates, unsigned count, uint32_t desired, unsigned *div)
{
	int best = -1;
	unsigned bd = 0;
	for (unsigned l = 0; l < count; l++) {
		unsigned d;
		if (rates[l] && geniclk_fits(rates[l], desired, &d) && (best < 0 || rates[l] < rates[best])) {
			best = (int)l;
			bd = d;
		}
	}
	if (best >= 0)
		*div = bd;
	return best;
}
#endif
