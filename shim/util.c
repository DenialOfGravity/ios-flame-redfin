#include "util.h"

void vzero(void *p, unsigned long n)
{
	volatile uint8_t *b = p;
	for (unsigned long i = 0; i < n; i++)
		b[i] = 0;
}

void vcopy(void *dst, const void *src, unsigned long n)
{
	volatile uint8_t *d = dst;
	const volatile uint8_t *s = src;
	for (unsigned long i = 0; i < n; i++)
		d[i] = s[i];
}

/* The compiler may emit calls to these for struct copies and zeroing. */
void *memset(void *p, int c, unsigned long n)
{
	volatile uint8_t *b = p;
	for (unsigned long i = 0; i < n; i++)
		b[i] = (uint8_t)c;
	return p;
}

void *memcpy(void *dst, const void *src, unsigned long n)
{
	vcopy(dst, src, n);
	return dst;
}

uint64_t ticks_now(void)
{
	uint64_t t;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	return t;
}

void delay_ms(unsigned ms)
{
	uint64_t end = ticks_now() + rsr("cntfrq_el0") / 1000 * ms;
	while (ticks_now() < end)
		;
}

uint64_t smc_call(uint64_t fn, uint64_t a1, uint64_t a2, uint64_t a3)
{
	register uint64_t x0 __asm__("x0") = fn;
	register uint64_t x1 __asm__("x1") = a1;
	register uint64_t x2 __asm__("x2") = a2;
	register uint64_t x3 __asm__("x3") = a3;
	__asm__ volatile("smc #0"
			 : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3)
			 :
			 : "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11",
			   "x12", "x13", "x14", "x15", "x16", "x17", "memory");
	return x0;
}

/* SMCCC call with up to five arguments after the function id (x1-x5). */
uint64_t smc_call5(uint64_t fn, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4,
		   uint64_t a5, uint64_t *r1)
{
	register uint64_t x0 __asm__("x0") = fn;
	register uint64_t x1 __asm__("x1") = a1;
	register uint64_t x2 __asm__("x2") = a2;
	register uint64_t x3 __asm__("x3") = a3;
	register uint64_t x4 __asm__("x4") = a4;
	register uint64_t x5 __asm__("x5") = a5;
	__asm__ volatile("smc #0"
			 : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4), "+r"(x5)
			 :
			 : "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
			   "x16", "x17", "memory");
	if (r1)
		*r1 = x1;
	return x0;
}
