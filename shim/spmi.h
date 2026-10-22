#pragma once
#include <stdint.h>

int spmi_init(void);
int spmi_read(uint32_t sid, uint32_t addr, uint8_t *out);
int spmi_write(uint32_t sid, uint32_t addr, uint8_t val);
