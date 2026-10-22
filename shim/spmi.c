/*
 * PMIC arbiter v5 access (qcom,spmi@c440000 in the flame live FDT, EE 0).
 *
 * Reads use the observer channel, writes the read/write channel of the
 * peripheral's APID, which the arbiter only accepts when the apps EE owns
 * the peripheral. Register map as in Linux drivers/spmi/spmi-pmic-arb.c.
 */
#include <stdint.h>
#include "log.h"
#include "spmi.h"
#include "util.h"

#define CORE_PA		0x0c440000UL
#define CHNLS_PA	0x0c600000UL
#define OBS_PA		0x0e600000UL
#define CNFG_PA		0x0c40a000UL

#define APID_MAP(n)	(0x900 + 4 * (n))	/* core: [19:8] PPID */
#define OWNER(n)	(0x700 + 4 * (n))	/* cnfg: [2:0] owner EE */

#define CH_CMD		0x00
#define CH_STATUS	0x08
#define CH_WDATA0	0x10
#define CH_RDATA0	0x18

#define OP_EXT_WRITEL	0
#define OP_EXT_READL	1

#define NO_APID		0xffff

static uint32_t napids;

int spmi_init(void)
{
	uint32_t ver = rd32(CORE_PA);
	napids = rd32(CORE_PA + 4) & 0x7ff;
	log_printf("spmi: arb version %x apids %u\n", ver, napids);
	if (ver < 0x50000000u || ver >= 0x70000000u || !napids || napids > 512) {
		napids = 0;
		return -1;
	}
	return 0;
}

/* APID for a PPID, preferring an entry the apps EE (0) owns. */
static uint32_t find_apid(uint32_t ppid, uint32_t *owner)
{
	uint32_t found = NO_APID;
	for (uint32_t i = 0; i < napids; i++) {
		uint32_t map = rd32(CORE_PA + APID_MAP(i));
		if (!map || ((map >> 8) & 0xfff) != ppid)
			continue;
		uint32_t own = rd32(CNFG_PA + OWNER(i)) & 7;
		if (found == NO_APID || own == 0) {
			found = i;
			*owner = own;
		}
	}
	return found;
}

static int wait_done(uintptr_t ch, uint32_t *status)
{
	uint64_t start = ticks_now();
	for (;;) {
		uint32_t st = rd32(ch + CH_STATUS);
		if (st & 1) {
			*status = st;
			return st & 0x0e ? -2 : 0;
		}
		if (ticks_now() - start > 19200000ULL / 10) {	/* 100 ms */
			*status = st;
			return -3;
		}
	}
}

int spmi_read(uint32_t sid, uint32_t addr, uint8_t *out)
{
	uint32_t owner = 7, st = 0;
	uint32_t apid = find_apid(sid << 8 | (addr >> 8 & 0xff), &owner);
	if (apid == NO_APID)
		return -1;
	uintptr_t ch = OBS_PA + 0x80UL * apid;	/* EE 0 */
	wr32(ch + CH_CMD, OP_EXT_READL << 27 | (addr & 0xff) << 4);
	int rc = wait_done(ch, &st);
	if (rc) {
		log_printf("spmi: read %x:%x apid %u status %x\n", sid, addr, apid, st);
		return rc;
	}
	*out = rd32(ch + CH_RDATA0) & 0xff;
	return 0;
}

int spmi_write(uint32_t sid, uint32_t addr, uint8_t val)
{
	uint32_t owner = 7, st = 0;
	uint32_t apid = find_apid(sid << 8 | (addr >> 8 & 0xff), &owner);
	if (apid == NO_APID || owner != 0) {
		log_printf("spmi: write %x:%x refused (apid %x owner %u)\n", sid, addr, apid, owner);
		return -1;
	}
	uintptr_t ch = CHNLS_PA + 0x10000UL * apid;
	wr32(ch + CH_WDATA0, val);
	wr32(ch + CH_CMD, OP_EXT_WRITEL << 27 | (addr & 0xff) << 4);
	int rc = wait_done(ch, &st);
	if (rc)
		log_printf("spmi: write %x:%x apid %u status %x\n", sid, addr, apid, st);
	return rc;
}
