#pragma once
#include <stdint.h>

/*
 * Text console on the splash framebuffer ABL scans out. Geometry comes from
 * the display pipe at runtime (con_init); 32 bpp, little-endian a8r8g8b8.
 */
#define FB_SPLASH_BASE	0x9c000000UL	/* sunfish cont_splash_region@9c000000 */
#define FB_SPLASH_SIZE	0x01700000UL
#define FB_W		1080
#define FB_H		2340

#define RED	0xffff0000U
#define BLUE	0xff0000a0U
#define WHITE	0xffffffffU
#define YELLOW	0xffffff00U
#define GREEN	0xff00ff00U

/* Returns 0 if the buffer is usable (inside the splash region). */
int con_init(uintptr_t base, uint32_t stride);
void con_clear(uint32_t bg);
void con_skip(void);
void con_home(void);
int con_rows(void);
unsigned con_text(const char *s, unsigned len, uint32_t fg);
void con_str(const char *label, const char *s);
void con_hex(const char *label, uint64_t v);
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb);
