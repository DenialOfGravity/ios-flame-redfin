#pragma once
#include <stdint.h>

struct sde_state {
	uintptr_t ctl, pipe, intf;	/* the active CTL, first fetching pipe, INTF_1 */
	int pipe_index;
	uint32_t tear_en;
};

extern struct sde_state sde;

void sde_probe(void);
void sde_sample(const char *what, int n, unsigned ms);
void sde_kick(void);
void sde_autorefresh(int frames);
