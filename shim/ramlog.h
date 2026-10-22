#pragma once
#include <stdint.h>

/* Rescue the previous kernel's console ring from RAM (before loading a new one). */
void ramlog_rescue(void);
/* Tell the next boot where this kernel's console ring is. */
void ramlog_arm(uint64_t ring_pa, uint64_t total_pa);
