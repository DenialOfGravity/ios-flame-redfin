/*
 * WCN3998 BT rails (live DT /soc/bt_wcn3990): vdd-io pm8150_s4 (smpa4, 1.8 V fixed), vdd-core pm8150a_l2
 * (ldoc2, 1.304 V), vdd-pa pm8150a_l10 (ldoc10, 3.0-3.312 V), vdd-xtal pm8150_l14 (ldoa14, 1.8 V).
 * There is no bt_en GPIO: the rails plus the 0xFC power pulse on the UART turn BT on.
 * wland (phone/wifi/wland.c wlan_power) votes ldoa14 / ldoc2 / ldoc10 for WLAN from the same apps DRV;
 * a vote here replaces that DRV's vote, so the same values are voted again (wland's
 * /var/local/wlan-rails.conf overrides honoured) and nothing is ever un-voted. smpa4 gets voltage +
 * enable only (its mode stays as the boot loader set it).
 * RPMh VRM offsets (qcom-rpmh-regulator): 0 voltage mV, 4 enable, 8 mode (PMIC5 LDO HPM = 7).
 */
#include <stdio.h>
#include <string.h>
#include "pmem.h"
#include "uart.h"

#define SW_CTRL_IO	(0x0f900000ull + 0x1000ull * 73 + 4)	/* TLMM EAST, GPIO 73 IN_OUT */

static unsigned wland_mv(const char *res, unsigned def)
{
	FILE *f = fopen("/var/local/wlan-rails.conf", "r");
	char r[16];
	unsigned mv;
	if (!f)
		return def;
	while (fscanf(f, "%15s %u", r, &mv) == 2)
		if (!strcmp(r, res) && mv) {
			def = mv;
			break;
		}
	fclose(f);
	return def;
}

int bt_rails_on(int verbose)
{
	pm_init();
	int bad = 0;
	uint32_t off2[2] = { 0, 4 }, val2[2] = { 1800, 1 };
	int rc = pm_rpmh("smpa4", 2, off2, val2);
	printf("btd: rail smpa4 (vdd-io) 1800 mV on -> %d\n", rc);
	bad |= rc;
	static const struct { const char *res, *what; unsigned mv; } ldo[] = {
		{ "ldoa14", "vdd-xtal", 1800 }, { "ldoc2", "vdd-core", 1304 }, { "ldoc10", "vdd-pa", 3312 },
	};
	for (unsigned i = 0; i < 3; i++) {
		unsigned mv = wland_mv(ldo[i].res, ldo[i].mv);
		uint32_t off[3] = { 0, 8, 4 }, val[3] = { mv, 7, 1 };
		rc = pm_rpmh(ldo[i].res, 3, off, val);
		printf("btd: rail %s (%s) %u mV HPM on -> %d%s\n", ldo[i].res, ldo[i].what, mv, rc,
			mv != ldo[i].mv ? " (from wlan-rails.conf)" : "");
		bad |= rc;
	}
	(void)verbose;
	return bad ? -1 : 0;
}

int bt_sw_ctrl(void)
{
	pm_init();
	uint32_t v = rd32(SW_CTRL_IO);
	return v == 0xdeadbeef ? -1 : (int)(v & 1);
}
