/*
 * Minimal text console on the ABL splash framebuffer. With the MMU off
 * every access is Device memory, so stay aligned (-mstrict-align).
 */
#include "console.h"
#include "font.h"

#define SCALE		3
#define CH_W		(8 * SCALE)
#define CH_H		(16 * SCALE)
#define MARGIN		24
#define TOP		120	/* below the camera cutout */
#define LABEL_COLS	8

static volatile uint32_t *con_fb;
static uint32_t con_stride;	/* in pixels */
static uint32_t con_bg;
static int row;

int con_init(uintptr_t base, uint32_t stride)
{
	if (base < FB_SPLASH_BASE || stride < FB_W * 4 ||
	    base + (uint64_t)stride * FB_H > FB_SPLASH_BASE + FB_SPLASH_SIZE) {
		con_fb = 0;
		return -1;
	}
	con_fb = (volatile uint32_t *)base;
	con_stride = stride / 4;
	return 0;
}

void con_clear(uint32_t bg)
{
	con_bg = bg;
	row = 0;
	if (!con_fb)
		return;
	for (int y = 0; y < FB_H; y++) {
		volatile uint32_t *line = con_fb + y * con_stride;
		for (int x = 0; x < FB_W; x++)
			line[x] = bg;
	}
}

static void put_char(int col, char ch, uint32_t fg)
{
	if (ch < 0x20 || ch > 0x7e)
		ch = '?';
	const unsigned char *g = font8x16[ch - 0x20];
	int x0 = MARGIN + col * CH_W, y0 = TOP + row * CH_H;
	if (!con_fb || x0 + CH_W > FB_W || y0 + CH_H > FB_H)
		return;
	for (int gy = 0; gy < 16; gy++)
		for (int gx = 0; gx < 8; gx++) {
			uint32_t c = (g[gy] & (0x80 >> gx)) ? fg : con_bg;
			for (int sy = 0; sy < SCALE; sy++) {
				volatile uint32_t *p = con_fb + (y0 + gy * SCALE + sy) * con_stride
						       + x0 + gx * SCALE;
				for (int sx = 0; sx < SCALE; sx++)
					p[sx] = c;
			}
		}
}

static int put_str(int col, const char *s, uint32_t fg)
{
	while (*s)
		put_char(col++, *s++, fg);
	return col;
}

static void fmt_hex(char *buf, uint64_t v, int digits)
{
	static const char hex[] = "0123456789ABCDEF";
	for (int i = 0; i < digits; i++)
		buf[i] = hex[(v >> (4 * (digits - 1 - i))) & 0xf];
	buf[digits] = 0;
}

void con_skip(void)
{
	row++;
}

void con_home(void)
{
	row = 0;
}

int con_rows(void)
{
	return (FB_H - TOP) / CH_H;
}

/*
 * Wrapped text from the current row down; returns how many bytes of s fit.
 * Non-printable bytes show as '?', tabs as one space, "\r" is dropped.
 * fg 0 only measures: rows advance, nothing is drawn.
 */
unsigned con_text(const char *s, unsigned len, uint32_t fg)
{
	const int cols = (FB_W - 2 * MARGIN) / CH_W;
	int col = 0;
	unsigned i = 0;
	while (i < len) {
		if (row >= con_rows())
			return i;
		char c = s[i];
		if (c == '\n' || col == cols) {
			row++;
			col = 0;
			if (c == '\n')
				i++;
			continue;
		}
		i++;
		if (c == '\r')
			continue;
		if (fg)
			put_char(col, c == '\t' ? ' ' : c, fg);
		col++;
	}
	if (col)
		row++;
	return i;
}

void con_str(const char *label, const char *s)
{
	put_str(0, label, YELLOW);
	put_str(LABEL_COLS, s, WHITE);
	row++;
}

void con_hex(const char *label, uint64_t v)
{
	char buf[17];
	fmt_hex(buf, v, 16);
	con_str(label, buf);
}

void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb)
{
	char buf[9];
	int col = put_str(0, label, YELLOW);
	col = col < LABEL_COLS ? LABEL_COLS : col + 1;
	col = put_str(col, a, YELLOW);
	fmt_hex(buf, va, 8);
	col = put_str(col, buf, WHITE);
	if (b) {
		col = put_str(col + 1, b, YELLOW);
		fmt_hex(buf, vb, 8);
		put_str(col, buf, WHITE);
	}
	row++;
}
