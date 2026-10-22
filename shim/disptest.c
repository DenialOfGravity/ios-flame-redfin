/*
 * Display test mode (built with -DSHIM_DISPTEST).
 *
 * Phases A-D (2026-10-20) showed that ABL's INTF1 autorefresh keeps the
 * command-mode panel fed, and that a CTL_START kick on top wedges it.
 *
 * Phases F/G test no-copy scanout for XNU: three buffers laid out like
 * backboardd's IOSurfaces (1125x2436, 4608-byte rows) in the splash
 * carve-out, cropped to the 1080x2280 panel with SRC_XY (22, 78), and the
 * two pipes flipped between them once a second:
 *
 *   F  SRC0_ADDR + CTL_FLUSH only (autorefresh keeps running)
 *   G  autorefresh off, flush, one kick, autorefresh back on
 *
 * Each buffer has its own colour, a white frame on the panel crop edges and
 * a white block whose height counts the buffer number. The pipe registers
 * and the flush register's readback go to the log.
 */
#include <stdint.h>
#include "console.h"
#include "disptest.h"
#include "log.h"
#include "sde.h"
#include "util.h"

#define PHASE_SECS	8
#define BLOCK		160

#define VIG0		0x0ae05000UL
#define VIG1		0x0ae07000UL
#define SRC_SIZE	0x00
#define SRC_IMG		0x04
#define SRC_XY		0x08
#define OUT_SIZE	0x0c
#define OUT_XY		0x10
#define SRC0_ADDR	0x14
#define YSTRIDE0	0x24
#define CTL_FLUSH	0x18
#define FLUSH_VIG01	0x3u
#define FLUSH_CTL	(1u << 17)
#define AUTOREFRESH	0x2b4

#define SURF_W		1125
#define SURF_H		2436
#define SURF_STRIDE	4608
#define SURF_SIZE	((uint64_t)SURF_STRIDE * SURF_H)
#define OFF_X		((SURF_W - FB_W) / 2)	/* 22 */
#define OFF_Y		((SURF_H - FB_H) / 2)	/* 78 */

static volatile uint32_t *fb;
static uint32_t stride;		/* pixels */

static void fill(int x0, int y0, int w, int h, uint32_t c)
{
	for (int y = y0; y < y0 + h; y++) {
		volatile uint32_t *line = fb + (uint64_t)y * stride;
		for (int x = x0; x < x0 + w; x++)
			line[x] = c;
	}
}

static void phase(const char *name, uint32_t bg, int kick)
{
	log_printf("disptest %s: autorefresh %x\n", name, rd32(sde.intf + AUTOREFRESH));
	fill(0, 0, FB_W, FB_H, bg);
	con_home();
	con_skip();
	con_text(name, 16, WHITE);
	if (kick)
		sde_kick();
	uint64_t hz = rsr("cntfrq_el0"), t0 = ticks_now();
	for (int s = 0; s < PHASE_SECS; s++) {
		int y = 400 + (s % 8) * (BLOCK + 40);
		if (s)
			fill(200, 400 + ((s - 1) % 8) * (BLOCK + 40), BLOCK, BLOCK, bg);
		fill(200, y, BLOCK, BLOCK, WHITE);
		if (kick)
			sde_kick();
		log_printf("  %s t=%d tear %x/%x start %x\n", name, s, rd32(sde.intf + 0x298),
			   rd32(sde.intf + 0x2b0), rd32(sde.ctl + 0x1c));
		while (ticks_now() - t0 < (uint64_t)(s + 1) * hz)
			;
	}
}

static void log_pipe(const char *name, uintptr_t p)
{
	log_printf("  %s: size %x img %x xy %x out %x/%x addr %x stride %x\n", name,
		   rd32(p + SRC_SIZE), rd32(p + SRC_IMG), rd32(p + SRC_XY), rd32(p + OUT_SIZE),
		   rd32(p + OUT_XY), rd32(p + SRC0_ADDR), rd32(p + YSTRIDE0));
}

/* One surface in its logical 1125x2436 layout. */
static void surf_draw(uintptr_t base, uint32_t bg, int n)
{
	volatile uint32_t *s = (volatile uint32_t *)base;
	const uint32_t sp = SURF_STRIDE / 4;
	for (int y = 0; y < SURF_H; y++) {
		volatile uint32_t *line = s + (uint64_t)y * sp;
		int edge_y = y >= OFF_Y && y < OFF_Y + FB_H &&
			     (y < OFF_Y + 8 || y >= OFF_Y + FB_H - 8);
		for (int x = 0; x < SURF_W; x++) {
			int in_x = x >= OFF_X && x < OFF_X + FB_W;
			int edge = in_x && (edge_y || (y >= OFF_Y && y < OFF_Y + FB_H &&
				   (x < OFF_X + 8 || x >= OFF_X + FB_W - 8)));
			int block = x >= 400 && x < 700 && y >= 600 && y < 600 + 200 * (n + 1);
			line[x] = edge || block ? WHITE : bg;
		}
	}
}

static void point_pipes(uintptr_t buf)
{
	const uintptr_t pipes[2] = { VIG0, VIG1 };
	for (int i = 0; i < 2; i++) {
		wr32(pipes[i] + SRC_IMG, (SURF_H << 16) | SURF_W);
		wr32(pipes[i] + SRC_XY, (OFF_Y << 16) | (OFF_X + 540 * i));
		wr32(pipes[i] + YSTRIDE0, SURF_STRIDE);
		wr32(pipes[i] + SRC0_ADDR, (uint32_t)buf);
	}
}

static void flip_phase(const char *name, const uintptr_t bufs[3], int manual)
{
	uint64_t hz = rsr("cntfrq_el0"), t0 = ticks_now();
	log_printf("disptest %s\n", name);
	for (int s = 0; s < 9; s++) {
		uintptr_t b = bufs[s % 3];
		if (manual)
			wr32(sde.intf + AUTOREFRESH, 0);
		point_pipes(b);
		wr32(sde.ctl + CTL_FLUSH, FLUSH_VIG01 | FLUSH_CTL);
		uint32_t f0 = rd32(sde.ctl + CTL_FLUSH);
		if (manual) {
			sde_kick();
			delay_ms(40);
			wr32(sde.intf + AUTOREFRESH, (1u << 31) | 1);
		} else {
			delay_ms(40);
		}
		log_printf("  %s t=%d buf %x flush %x -> %x\n", name, s, (uint32_t)b, f0,
			   rd32(sde.ctl + CTL_FLUSH));
		while (ticks_now() - t0 < (uint64_t)(s + 1) * hz)
			;
	}
	log_pipe("vig0", VIG0);
	log_pipe("vig1", VIG1);
}

void disptest_run(void (*save)(const char *))
{
	fb = (volatile uint32_t *)(uintptr_t)rd32(sde.pipe + 0x14);
	stride = (rd32(sde.pipe + 0x24) & 0xffff) / 4;
	if (con_init((uintptr_t)fb, stride * 4) || !sde.intf || !sde.ctl) {
		log_printf("disptest: no framebuffer\n");
		return;
	}
	log_printf("disptest: ctl %lx flush %x\n", (uint64_t)sde.ctl, rd32(sde.ctl + CTL_FLUSH));
	log_pipe("vig0", VIG0);
	log_pipe("vig1", VIG1);
	phase("A no kick", 0xffa00000, 0);
	save("disptest A");

	const uintptr_t bufs[3] = {
		FB_SPLASH_BASE,
		FB_SPLASH_BASE + SURF_SIZE,
		FB_SPLASH_BASE + 2 * SURF_SIZE,
	};
	surf_draw(bufs[0], 0xffa00000, 0);
	surf_draw(bufs[1], 0xff00a000, 1);
	surf_draw(bufs[2], 0xff0000c0, 2);
	flip_phase("F flush only", bufs, 0);
	save("disptest F");
	flip_phase("G manual flush", bufs, 1);
	save("disptest G");
}
