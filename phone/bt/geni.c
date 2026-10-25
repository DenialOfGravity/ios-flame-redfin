/*
 * The WCN3998's HCI UART from userland: QUPv3 wrapper 0 SE5 (0x894000, msm-geni-serial-hs in the stock DT)
 * driven through /dev/pmem with its FIFOs polled. Register sequence after Linux qcom_geni_serial.c and
 * qcom-geni-se.c (FIFO mode); clocks from gcc-lito.c (gcc_qupv3_wrap0_s5_clk_src 0x17600, branch 0x175fc,
 * vote APCS_CLOCK_BRANCH_ENA_VOTE_1 0x52008 bit 15 + wrap0 m/s AHB 6/7, core 8, core_2x 9); pins
 * pinctrl-lito.c (EAST tile, GPIO 38 CTS, 39 RTS, 40 TX, 41 RX, function 1 = qup05, DT pulls).
 * HW flow control: the SE drops RTS itself when the RX FIFO reaches the RFR watermark (depth - 2 words),
 * so polling late loses nothing.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "pmem.h"
#include "uart.h"
#include "geniclk.h"

#define SE		0x00894000ull
#define WRAP0		0x008c0000ull
#define GCC		0x00100000ull
#define GCC_VOTE	(GCC + 0x52008)
#define GCC_BITS	((1u << 6) | (1u << 7) | (1u << 8) | (1u << 9) | (1u << 15))
#define RCG		(GCC + 0x17600)
#define TLMM_EAST	0x0f900000ull
#define PIN_CFG(n)	(TLMM_EAST + 0x1000ull * (n))

/* SE registers (geni-se.h, qcom_geni_serial.c) */
#define FORCE_DEFAULT	0x020
#define OUTPUT_CTRL	0x024
#define CGC_CTRL	0x028
#define GENI_STATUS	0x040
#define M_CLK_CFG	0x048
#define S_CLK_CFG	0x04c
#define IF_DISABLE_RO	0x064
#define FW_REVISION	0x068
#define FW_S_REVISION	0x06c
#define CLK_SEL		0x07c
#define UART_LOOPBACK	0x22c
#define BYTE_GRAN	0x254
#define DMA_MODE_EN	0x258
#define TX_TRANS_CFG	0x25c
#define TX_PACK0	0x260
#define TX_PACK1	0x264
#define TX_WORD_LEN	0x268
#define TX_STOP_LEN	0x26c
#define TX_TRANS_LEN	0x270
#define RX_TRANS_CFG	0x280
#define RX_PACK0	0x284
#define RX_PACK1	0x288
#define RX_WORD_LEN	0x28c
#define RX_STALE_CNT	0x294
#define TX_PARITY	0x2a4
#define RX_PARITY	0x2a8
#define MANUAL_RFR	0x2ac
#define M_CMD0		0x600
#define M_CMD_CTRL	0x604
#define M_IRQ_STATUS	0x610
#define M_IRQ_EN	0x614
#define M_IRQ_CLEAR	0x618
#define S_CMD0		0x630
#define S_CMD_CTRL	0x634
#define S_IRQ_STATUS	0x640
#define S_IRQ_EN	0x644
#define S_IRQ_CLEAR	0x648
#define TX_FIFO		0x700
#define RX_FIFO		0x780
#define TX_FIFO_STATUS	0x800
#define RX_FIFO_STATUS	0x804
#define TX_WM		0x80c
#define RX_WM		0x810
#define RX_RFR_WM	0x814
#define GENI_IOS	0x908
#define DMA_TX_IRQ_CLR	0xc44
#define DMA_RX_IRQ_CLR	0xd44
#define GSI_EVENT_EN	0xe18
#define SE_IRQ_EN	0xe1c
#define HW_PARAM_0	0xe24
#define HW_PARAM_1	0xe28
#define DMA_GEN_CFG	0xe30

#define M_ACTIVE	(1u << 0)
#define S_ACTIVE	(1u << 12)
#define CMD_DONE	(1u << 0)
#define CMD_CANCEL	(1u << 4)
#define CMD_ABORT	(1u << 5)
#define S_RX_WM_IRQ	(1u << 26)
#define S_RX_LAST_IRQ	(1u << 27)
#define S_RX_WR_ERR	(1u << 25)
#define S_GP_IRQS	(0xfu << 9)	/* parity / break */
#define M_TX_WM_IRQ	(1u << 30)
#define M_COMMON_EN	(0x7eu | (1u << 22) | (1u << 23) | (1u << 24) | (1u << 25) | (1u << 28) | (1u << 29))
#define S_COMMON_EN	(0x3eu | (0x1fu << 9) | (1u << 24) | (1u << 25))
#define CTS_MASK	(1u << 1)
#define RFR_MANUAL_NOT_READY ((1u << 31) | (1u << 1))
#define UART_START	(1u << 27)	/* opcode 1 in both M_CMD0 and S_CMD0 */
/* 8-bit words, 4 per FIFO entry, LSB first (geni_se_config_packing(se, 8, 4, false, ..)) */
#define PACK0		0x0004380eu
#define PACK1		0x000c3e0eu

struct geni {
	struct uart u;
	int verbose, os, dfs;
	unsigned depth;			/* FIFO words */
	uint8_t pend[256];		/* bytes saved from the RX FIFO across a baud change */
	unsigned npend, pend_pos;
	unsigned long rx_bytes, tx_bytes, rx_overruns, rx_gp;
};

static uint32_t se_rd(uint32_t off)
{
	return rd32(SE + off);
}

static void se_wr(uint32_t off, uint32_t v)
{
	wr32(SE + off, v);
}

static int se_wait(uint32_t off, uint32_t mask, int set, unsigned us)
{
	for (unsigned i = 0; i <= us; i += 10) {
		if (!!(se_rd(off) & mask) == set)
			return 0;
		usleep(10);
	}
	return -1;
}

static int clocks_on(int verbose)
{
	uint32_t v = rd32(GCC_VOTE);
	wr32(GCC_VOTE, v | GCC_BITS);
	printf("btd: GCC vote 0x52008 %#x -> %#x\n", v, rd32(GCC_VOTE));
	static const struct { uint32_t off; const char *name; } br[] = {
		{ 0x17004, "wrap0 m_ahb" }, { 0x17008, "wrap0 s_ahb" }, { 0x23000, "wrap0 core" },
		{ 0x23008, "wrap0 core_2x" }, { 0x175fc, "wrap0 s5" },
	};
	int bad = 0;
	for (unsigned i = 0; i < sizeof(br) / sizeof(br[0]); i++) {
		uint32_t c = 0;
		int ok = 0;
		for (int t = 0; t < 50 && !ok; t++) {
			c = rd32(GCC + br[i].off);
			ok = (c & 2u) || !(c & (1u << 31));	/* hardware-gated branches read "off" while idle */
			if (!ok)
				usleep(100);
		}
		if (verbose || !ok)
			printf("btd: GCC branch %#x (%s) = %#x%s\n", br[i].off, br[i].name, c, ok ? "" : " HALTED");
		bad += !ok && br[i].off != 0x23000 && br[i].off != 0x23008;
	}
	return bad ? -1 : 0;
}

/* gcc_qupv3_wrap0_s5_clk_src to row r (no DFS), or pick the DFS level; returns the source rate or 0 */
static uint32_t rcg_set(struct geni *g, uint32_t desired, unsigned *div)
{
	uint32_t dfs = rd32(RCG + 0x14);
	if (dfs & 1) {
		uint32_t rates[8];
		for (unsigned l = 0; l < 8; l++) {
			rates[l] = geniclk_dfs_rate(rd32(RCG + 0x1c + 4 * l), rd32(RCG + 0x5c + 4 * l), rd32(RCG + 0x9c + 4 * l));
			if (g->verbose)
				printf("btd: RCG DFS level %u: %u Hz\n", l, rates[l]);
		}
		int l = geniclk_pick_dfs(rates, 8, desired, div);
		if (l < 0) {
			printf("btd: no DFS level gives %u Hz\n", desired);
			return 0;
		}
		se_wr(CLK_SEL, (uint32_t)l);
		g->dfs = 1;
		return rates[l];
	}
	const struct geniclk_row *r = geniclk_pick(desired, div);
	if (!r) {
		printf("btd: no clock row for %u Hz\n", desired);
		return 0;
	}
	if (r->n) {
		wr32(RCG + 0x8, r->m);
		wr32(RCG + 0xc, ~(r->n - r->m) & 0xffffu);
		wr32(RCG + 0x10, ~r->n & 0xffffu);
	}
	uint32_t cfg = rd32(RCG + 4) & ~(0x371fu | (1u << 20));
	cfg |= r->hid | (uint32_t)r->src << 8 | (r->n ? 2u << 12 : 0);
	wr32(RCG + 4, cfg);
	wr32(RCG, rd32(RCG) | 1);
	if (wait_bit(RCG, 1, 0, 5))
		printf("btd: RCG 0x17600 update did not finish (cmd %#x)\n", rd32(RCG));
	se_wr(CLK_SEL, 0);
	return r->rate;
}

static void stop_rx(struct geni *g)
{
	/* keep what is already in the FIFO */
	uint32_t st = se_rd(RX_FIFO_STATUS);
	(void)st;
	if (se_rd(GENI_STATUS) & S_ACTIVE) {
		se_wr(S_CMD_CTRL, 1u << 2);	/* cancel */
		if (se_wait(S_IRQ_STATUS, CMD_CANCEL, 1, 2000)) {
			se_wr(S_CMD_CTRL, 1u << 1);	/* abort */
			se_wait(S_CMD_CTRL, 1u << 1, 0, 2000);
			se_wr(FORCE_DEFAULT, 1);
		}
	}
	/* drain into pend (the controller may already be answering) */
	while (g->npend + 4 <= sizeof(g->pend)) {
		uint32_t s = se_rd(RX_FIFO_STATUS), wc = s & 0x1ffffffu;
		if (!wc)
			break;
		uint32_t w = se_rd(RX_FIFO);
		unsigned nb = (wc == 1 && (s >> 31) && ((s >> 28) & 7)) ? (s >> 28) & 7 : 4;
		for (unsigned i = 0; i < nb; i++)
			g->pend[g->npend++] = (uint8_t)(w >> (8 * i));
	}
	se_wr(S_IRQ_CLEAR, 0xffffffffu);
}

static void start_rx(void)
{
	se_wr(S_CMD0, UART_START);
}

static int g_set_baud(struct uart *u, unsigned baud)
{
	struct geni *g = u->priv;
	unsigned div = 0;
	stop_rx(g);
	uint32_t src = rcg_set(g, baud * (unsigned)g->os, &div);
	if (!src) {
		start_rx();
		return -1;
	}
	se_wr(M_CLK_CFG, div << 4 | 1);
	se_wr(S_CLK_CFG, div << 4 | 1);
	start_rx();
	u->baud = baud;
	if (g->verbose)
		printf("btd: UART %u Bd: source %u Hz / %u / %d oversampling (%s)\n", baud, src, div, g->os,
			g->dfs ? "DFS level" : "RCG programmed");
	return 0;
}

static int g_set_flow(struct uart *u, int on)
{
	uint32_t t = se_rd(TX_TRANS_CFG);
	se_wr(TX_TRANS_CFG, on ? t & ~CTS_MASK : t | CTS_MASK);
	se_wr(MANUAL_RFR, on ? 0 : RFR_MANUAL_NOT_READY);
	u->flow = on;
	return 0;
}

static void cancel_tx(void)
{
	se_wr(M_CMD_CTRL, 1u << 2);
	if (se_wait(M_IRQ_STATUS, CMD_CANCEL, 1, 2000)) {
		se_wr(M_CMD_CTRL, 1u << 1);
		se_wait(M_IRQ_STATUS, CMD_ABORT, 1, 2000);
	}
	se_wr(M_IRQ_CLEAR, 0xffffffffu);
}

static int g_write(struct uart *u, const uint8_t *buf, size_t n)
{
	struct geni *g = u->priv;
	if (!n)
		return 0;
	if (se_wait(GENI_STATUS, M_ACTIVE, 0, 100000)) {
		printf("btd: TX: previous command still active (status %#x); cancelling\n", se_rd(GENI_STATUS));
		cancel_tx();
	}
	se_wr(M_IRQ_CLEAR, 0xffffffffu);
	se_wr(TX_TRANS_LEN, (uint32_t)n);
	se_wr(M_CMD0, UART_START);
	size_t off = 0;
	uint64_t last = now_ms();
	while (off < n) {
		uint32_t wc = se_rd(TX_FIFO_STATUS) & 0x0fffffffu;
		unsigned space = wc < g->depth ? g->depth - wc : 0;
		if (!space) {
			if (now_ms() - last > 500) {
				uint32_t ios = se_rd(GENI_IOS);
				printf("btd: TX stuck at %zu/%zu bytes: CTS %s (IOS %#x), flow %s\n", off, n,
					ios & 2 ? "not ready" : "ready", ios, u->flow ? "on" : "off");
				cancel_tx();
				return -1;
			}
			usleep(50);
			continue;
		}
		last = now_ms();
		while (space-- && off < n) {
			uint32_t w = 0;
			for (unsigned i = 0; i < 4 && off < n; i++)
				w |= (uint32_t)buf[off++] << (8 * i);
			se_wr(TX_FIFO, w);
		}
	}
	g->tx_bytes += n;
	/* done = the last bit left the shifter (with flow control: the controller took it) */
	unsigned us = (unsigned)(n * 10 * 1000000ull / u->baud) * 2 + 50000;
	if (se_wait(M_IRQ_STATUS, CMD_DONE, 1, us)) {
		uint32_t ios = se_rd(GENI_IOS);
		printf("btd: TX of %zu bytes not done in %u us: CTS %s (IOS %#x)\n", n, us, ios & 2 ? "not ready" : "ready", ios);
		cancel_tx();
		return -1;
	}
	se_wr(M_IRQ_CLEAR, CMD_DONE | M_TX_WM_IRQ);
	return 0;
}

static int g_drain(struct uart *u, unsigned ms)
{
	(void)u;
	return se_wait(GENI_STATUS, M_ACTIVE, 0, ms * 1000) ? -1 : 0;
}

static int g_read(struct uart *u, uint8_t *buf, size_t n, unsigned ms)
{
	struct geni *g = u->priv;
	size_t got = 0;
	while (g->pend_pos < g->npend && got < n)
		buf[got++] = g->pend[g->pend_pos++];
	if (g->pend_pos >= g->npend)
		g->pend_pos = g->npend = 0;
	if (got)
		return (int)got;
	uint64_t end = now_ms() + ms;
	for (;;) {
		uint32_t s = se_rd(RX_FIFO_STATUS), wc = s & 0x1ffffffu;
		if (wc) {
			/* the last word is partial only when the FIFO says so (stale timeout pushed it) */
			while (wc && got + 4 <= n) {
				uint32_t w = se_rd(RX_FIFO);
				unsigned nb = (wc == 1 && (s >> 31) && ((s >> 28) & 7)) ? (s >> 28) & 7 : 4;
				for (unsigned i = 0; i < nb; i++)
					buf[got++] = (uint8_t)(w >> (8 * i));
				wc--;
			}
			uint32_t irq = se_rd(S_IRQ_STATUS);
			if (irq & (S_RX_WR_ERR | S_GP_IRQS)) {
				if (irq & S_RX_WR_ERR)
					g->rx_overruns++;
				if (irq & S_GP_IRQS)
					g->rx_gp++;
				printf("btd: RX error irq %#x (overruns %lu, parity/break %lu)\n", irq, g->rx_overruns, g->rx_gp);
			}
			se_wr(S_IRQ_CLEAR, irq);
			g->rx_bytes += got;
			return (int)got;
		}
		if (now_ms() >= end)
			return 0;
		usleep(100);
	}
}

static void g_flush_rx(struct uart *u)
{
	struct geni *g = u->priv;
	g->npend = g->pend_pos = 0;
	for (int i = 0; i < 1024; i++) {
		uint32_t wc = se_rd(RX_FIFO_STATUS) & 0x1ffffffu;
		if (!wc)
			break;
		while (wc--)
			(void)se_rd(RX_FIFO);
	}
	se_wr(S_IRQ_CLEAR, 0xffffffffu);
}

static void g_close(struct uart *u)
{
	struct geni *g = u->priv;
	printf("btd: GENI UART closed: rx %lu tx %lu bytes, overruns %lu, parity/break %lu\n", g->rx_bytes,
		g->tx_bytes, g->rx_overruns, g->rx_gp);
	free(g);
}

static void pins(int verbose)
{
	/* [1:0] pull (0 none, 1 down, 3 up), [5:2] function, [8:6] drive (mA / 2 - 1) */
	static const struct { unsigned pin, pull; const char *what; } p[] = {
		{ 38, 0, "CTS" }, { 39, 1, "RTS" }, { 40, 3, "TX" }, { 41, 0, "RX" },
	};
	for (unsigned i = 0; i < 4; i++) {
		uint32_t old = rd32(PIN_CFG(p[i].pin));
		wr32(PIN_CFG(p[i].pin), (old & ~0x3ffu) | 1u << 2 | p[i].pull);
		if (verbose)
			printf("btd: GPIO %u (%s) cfg %#x -> %#x\n", p[i].pin, p[i].what, old, rd32(PIN_CFG(p[i].pin)));
	}
}

struct uart *geni_open(int verbose, int oversampling)
{
	pm_init();
	if (clocks_on(verbose)) {
		printf("btd: SE5 clocks did not come up; not touching the SE (a read would hang)\n");
		return NULL;
	}
	uint32_t fw = se_rd(FW_REVISION), fws = se_rd(FW_S_REVISION), ifd = se_rd(IF_DISABLE_RO);
	uint32_t p0 = se_rd(HW_PARAM_0), p1 = se_rd(HW_PARAM_1), hw = rd32(WRAP0 + 4), st = se_rd(GENI_STATUS);
	unsigned proto = (fw >> 8) & 0xff;
	printf("btd: SE5 GENI_FW_REVISION_RO %#x (protocol %u%s, version %u) S %#x, FIFO interface %s, "
		"QUP hw version %#x, status %#x, TX FIFO %u x %u bits, RX FIFO %u x %u bits\n",
		fw, proto, proto == 2 ? " = UART" : proto == 1 ? " = SPI" : proto == 3 ? " = I2C" : proto == 0 ? " = none" : "",
		fw & 0xff, fws, ifd & 1 ? "DISABLED" : "enabled", hw, st, (p0 >> 16) & 0x3f, (p0 >> 24) & 0x3f,
		(p1 >> 16) & 0x3f, (p1 >> 24) & 0x3f);
	if (proto != 2) {
		printf("btd: SE5 has no UART firmware (protocol %u): XBL did not load it; loading SE firmware is a "
			"separate task. Stopping.\n", proto);
		return NULL;
	}
	if (ifd & 1) {
		printf("btd: SE5 FIFO interface disabled (GSI/DMA only); stopping\n");
		return NULL;
	}
	struct geni *g = calloc(1, sizeof(*g));
	g->verbose = verbose;
	g->depth = (p0 >> 16) & 0x3f;
	if (((p0 >> 24) & 0x3f) != 32 || ((p1 >> 24) & 0x3f) != 32 || g->depth < 4) {
		printf("btd: unexpected FIFO geometry; stopping\n");
		free(g);
		return NULL;
	}
	g->os = oversampling ? oversampling : (hw >= 0x20050000u && hw != 0xffffffffu ? 16 : 32);
	unsigned rx_depth = (p1 >> 16) & 0x3f;
	pins(verbose);
	if (st & (M_ACTIVE | S_ACTIVE)) {
		printf("btd: SE5 busy at start (status %#x): cancelling\n", st);
		cancel_tx();
		stop_rx(g);
		g->npend = 0;
	}
	/* qcom_geni_serial_port_setup + geni_se_init + FIFO mode, then set_termios */
	se_wr(RX_STALE_CNT, 10 * 16);
	se_wr(TX_PACK0, PACK0);
	se_wr(TX_PACK1, PACK1);
	se_wr(RX_PACK0, PACK0);
	se_wr(RX_PACK1, PACK1);
	se_wr(BYTE_GRAN, 0);
	se_wr(GSI_EVENT_EN, 0);
	se_wr(M_IRQ_CLEAR, 0xffffffffu);
	se_wr(S_IRQ_CLEAR, 0xffffffffu);
	se_wr(DMA_TX_IRQ_CLR, 0xffffffffu);
	se_wr(DMA_RX_IRQ_CLR, 0xffffffffu);
	se_wr(CGC_CTRL, se_rd(CGC_CTRL) | 0x7f);
	se_wr(DMA_GEN_CFG, se_rd(DMA_GEN_CFG) | 0xf);
	se_wr(OUTPUT_CTRL, 0x7f);
	se_wr(FORCE_DEFAULT, 1);
	se_wr(SE_IRQ_EN, se_rd(SE_IRQ_EN) | 0xf);	/* nothing at the GIC listens unless 0981 attached SPI 606 */
	se_wr(DMA_MODE_EN, se_rd(DMA_MODE_EN) & ~1u);
	se_wr(RX_WM, 2);
	se_wr(RX_RFR_WM, rx_depth - 2);
	se_wr(M_IRQ_EN, se_rd(M_IRQ_EN) | M_COMMON_EN | CMD_DONE | M_TX_WM_IRQ);
	se_wr(S_IRQ_EN, se_rd(S_IRQ_EN) | S_COMMON_EN | S_RX_WM_IRQ | S_RX_LAST_IRQ);
	se_wr(TX_WM, 0);
	se_wr(UART_LOOPBACK, 0);
	se_wr(TX_TRANS_CFG, 0);
	se_wr(TX_PARITY, 0);
	se_wr(RX_TRANS_CFG, 0);
	se_wr(RX_PARITY, 0);
	se_wr(TX_WORD_LEN, 8);
	se_wr(RX_WORD_LEN, 8);
	se_wr(TX_STOP_LEN, 0);
	g->u.name = "pmem";
	g->u.set_baud = g_set_baud;
	g->u.set_flow = g_set_flow;
	g->u.write = g_write;
	g->u.drain = g_drain;
	g->u.read = g_read;
	g->u.flush_rx = g_flush_rx;
	g->u.close = g_close;
	g->u.priv = g;
	g->u.baud = 115200;
	g_set_flow(&g->u, 1);
	if (g_set_baud(&g->u, 115200)) {
		free(g);
		return NULL;
	}
	printf("btd: SE5 UART up (polled over /dev/pmem): 115200 8N1, RTS/CTS, oversampling %d, FIFO %u words\n",
		g->os, g->depth);
	return &g->u;
}
