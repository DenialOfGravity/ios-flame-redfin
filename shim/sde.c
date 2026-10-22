/*
 * Display (MDSS/SDE 5.0) probing on flame.
 *
 * ABL leaves the NT37280 command-mode panel running: CTL_0 -> LM_0/LM_1
 * (540 px each, source split) -> PP_0/PP_1 -> DSC_0/DSC_1 -> INTF_1 (DSI0),
 * with tear check in INTF_1. Command mode only sends a frame when started,
 * so writes to the buffer do not show up by themselves. INTF_1's
 * autorefresh makes the hardware start one frame per TE pulse, which turns
 * the panel into a scanned-out framebuffer.
 *
 * Offsets: qcom,mdss_mdp@ae00000 in the live FDT and Linux's sde_hw_*.c.
 */
#include <stdint.h>
#include "log.h"
#include "sde.h"
#include "util.h"

#define MDP		0x0ae00000UL
#define CTL(n)		(MDP + 0x2000 + 0x200 * (n))
#define SSPP_VIG(n)	(MDP + 0x5000 + 0x2000 * (n))
#define SSPP_DMA(n)	(MDP + 0x25000 + 0x2000 * (n))
#define LM(n)		(MDP + 0x45000 + 0x1000 * (n))
#define PP(n)		(MDP + 0x71000 + 0x800 * (n))
#define DSC(n)		(MDP + 0x81000 + 0x400 * (n))
#define INTF(n)		(MDP + 0x6b000 + 0x800 * (n))

#define CTL_LAYER(lm)	(0x04 * (lm))
#define CTL_TOP		0x014
#define CTL_FLUSH	0x018
#define CTL_START	0x01c
#define CTL_DSC_ACTIVE	0x0e8
#define CTL_INTF_ACTIVE	0x0f4

#define SSPP_SRC_SIZE	0x00
#define SSPP_SRC0_ADDR	0x14
#define SSPP_YSTRIDE0	0x24
#define SSPP_FORMAT	0x30
#define SSPP_UNPACK	0x34
#define SSPP_OP_MODE	0x38

#define INTF_TEAR_EN		0x284
#define INTF_TEAR_INT_COUNT	0x298
#define INTF_TEAR_LINE_COUNT	0x2b0
#define INTF_TEAR_AUTOREFRESH	0x2b4

struct sde_state sde;

static void dump_block(const char *name, uintptr_t base, uint32_t len)
{
	log_printf("sde %s @%lx:", name, (uint64_t)base);
	int printed = 0;
	for (uint32_t off = 0; off < len; off += 4) {
		uint32_t v = rd32(base + off);
		if (!v)
			continue;
		log_printf(" %x=%x", off, v);
		if (++printed % 8 == 0)
			log_printf("\n  ");
	}
	log_printf("\n");
}

/* Which pipe feeds the given mixer, from CTL_LAYER (3 bits per pipe). */
static void log_pipes(void)
{
	for (int i = 0; i < 8; i++) {
		uintptr_t b = i < 4 ? SSPP_VIG(i) : SSPP_DMA(i - 4);
		uint32_t size = rd32(b + SSPP_SRC_SIZE);
		if (!size)
			continue;
		log_printf("sspp %s%d: size %ux%u addr %x stride %x fmt %x unpack %x op %x\n",
			   i < 4 ? "vig" : "dma", i & 3, size & 0xffff, size >> 16, rd32(b + SSPP_SRC0_ADDR),
			   rd32(b + SSPP_YSTRIDE0), rd32(b + SSPP_FORMAT), rd32(b + SSPP_UNPACK),
			   rd32(b + SSPP_OP_MODE));
		if (!sde.pipe) {
			sde.pipe = b;
			sde.pipe_index = i;
		}
	}
}

void sde_probe(void)
{
	log_printf("sde: hw %x\n", rd32(MDP));
	for (int i = 0; i < 6; i++) {
		uint32_t top = rd32(CTL(i) + CTL_TOP), intf = rd32(CTL(i) + CTL_INTF_ACTIVE);
		log_printf("ctl%d: layer0 %x layer1 %x top %x flush %x dsc %x intf %x\n", i,
			   rd32(CTL(i) + CTL_LAYER(0)), rd32(CTL(i) + CTL_LAYER(1)), top,
			   rd32(CTL(i) + CTL_FLUSH), rd32(CTL(i) + CTL_DSC_ACTIVE), intf);
		if (!sde.ctl && (intf & 2))
			sde.ctl = CTL(i);
	}
	log_pipes();
	dump_block("ctl0", CTL(0), 0x1e0);
	dump_block("lm0", LM(0), 0x320);
	dump_block("lm1", LM(1), 0x320);
	dump_block("pp0", PP(0), 0xd4);
	dump_block("pp1", PP(1), 0xd4);
	dump_block("dsc0", DSC(0), 0x140);
	dump_block("intf1", INTF(1), 0x2b8);
	if (sde.pipe)
		dump_block("pipe", sde.pipe, 0x1f0);
	sde.intf = INTF(1);
	sde.tear_en = rd32(sde.intf + INTF_TEAR_EN);
	log_printf("sde: ctl %lx pipe %lx tear %x autorefresh %x\n", (uint64_t)sde.ctl,
		   (uint64_t)sde.pipe, sde.tear_en, rd32(sde.intf + INTF_TEAR_AUTOREFRESH));
}

/* Sample the tear-check counters: a moving line count means frames are being sent. */
void sde_sample(const char *what, int n, unsigned ms)
{
	log_printf("sde %s:", what);
	for (int i = 0; i < n; i++) {
		log_printf(" %x/%x", rd32(sde.intf + INTF_TEAR_INT_COUNT),
			   rd32(sde.intf + INTF_TEAR_LINE_COUNT));
		delay_ms(ms);
	}
	log_printf("\n");
}

void sde_kick(void)
{
	if (sde.ctl)
		wr32(sde.ctl + CTL_START, 1);
}

/*
 * No CTL_START here: a kick while autorefresh runs wedges the pipe, and the
 * panel keeps its last frame with noise on top (disptest phase D, 2026-10-20).
 * Autorefresh starts frames by itself; a kick is only for manual mode.
 */
void sde_autorefresh(int frames)
{
	if (!sde.intf || !sde.tear_en)
		return;
	wr32(sde.intf + INTF_TEAR_AUTOREFRESH, frames ? (1u << 31) | (uint32_t)frames : 0);
	log_printf("sde: autorefresh -> %x\n", rd32(sde.intf + INTF_TEAR_AUTOREFRESH));
}
