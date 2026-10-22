#pragma once
#include <stdint.h>

/* Byte-wise helpers that stay correct on Device memory (MMU off). */
void vzero(void *p, unsigned long n);
void vcopy(void *dst, const void *src, unsigned long n);

static inline uint32_t rd32(uintptr_t a) { return *(volatile uint32_t *)a; }
static inline void wr32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })
#define wsr(r, v) __asm__ volatile("msr " r ", %0" : : "r"((uint64_t)(v)))

uint64_t ticks_now(void);
void delay_ms(unsigned ms);
uint64_t smc_call(uint64_t fn, uint64_t a1, uint64_t a2, uint64_t a3);
uint64_t smc_call5(uint64_t fn, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4,
		   uint64_t a5, uint64_t *r1);
