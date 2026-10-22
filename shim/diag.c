/*
 * Diag mode (built with -DSHIM_DIAG): show the PMIC PON blocks on screen and
 * count seconds, watchdog off, no UFS. Tells an external reset (PMIC, TZ,
 * hardware watchdog: the counter stops) from one ABL causes itself (the
 * counter keeps going). Resets into fastboot after DIAG_SECS.
 */
#include <stdint.h>
#include "console.h"
#include "diag.h"
#include "log.h"
#include "spmi.h"
#include "util.h"

#ifndef DIAG_SECS
#define DIAG_SECS	120
#endif

/* 16 bytes per row: "SS AAA: xx xx ... " fits the 43-column console with 2 rows. */
static void dump_block(uint32_t sid, uint32_t base)
{
	char line[64];
	for (uint32_t off = 0; off < 0x100; off += 8) {
		unsigned n = fmt_snprintf(line, sizeof(line), "%x:%03x", sid, base + off);
		for (uint32_t i = 0; i < 8; i++) {
			uint8_t v = 0;
			int rc = spmi_read(sid, base + off + i, &v);
			n += fmt_snprintf(line + n, sizeof(line) - n, rc ? " --" : " %02x", v);
		}
		log_printf("%s\n", line);
		con_text(line, n, WHITE);
	}
}

void diag_run(int spmi_ok)
{
	con_clear(0xff300030);
	con_text("DIAG pon sid0 / sid2", 20, YELLOW);
	if (spmi_ok) {
		dump_block(0, 0x800);
	} else {
		con_text("spmi init failed", 16, RED);
	}
	/* Second screen: the PM8150B PON block, then the counter below it. */
	delay_ms(6000);
	con_clear(0xff300030);
	con_text("DIAG pon sid2", 13, YELLOW);
	if (spmi_ok)
		dump_block(2, 0x800);
	int r = con_rows() - 2;
	(void)r;
	uint64_t t0 = ticks_now(), hz = rsr("cntfrq_el0");
	for (unsigned s = 0; s < DIAG_SECS; s++) {
		char line[48];
		unsigned n = fmt_snprintf(line, sizeof(line), "ALIVE %u s  wdt en %x", s,
					  rd32(0x17c10008UL));
		con_text(line, n, GREEN);
		while (ticks_now() - t0 < (s + 1) * hz)
			;
	}
}
