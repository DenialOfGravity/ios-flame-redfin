/*
 * Polled UFS access for the shim, on the host ABL leaves running.
 *
 * Runs with the MMU off (all memory Device, so DMA needs no cache
 * maintenance). Takes over the transfer request list with our own buffers
 * and issues one SCSI command at a time on LUN 0. Writes are restricted to
 * the scratch area at the end of the userdata partition (ufs_scratch_*),
 * nothing else on the device is ever written.
 *
 * Register layout and descriptor formats: JEDEC UFSHCI (JESD223).
 */
#include <stdint.h>
#include "log.h"
#include "ufs.h"
#include "util.h"

#define UFS_BASE	0x01d84000UL	/* ufshc@1d84000, flame live FDT */

#define REG_CAP		0x00
#define REG_VER		0x08
#define REG_IS		0x20
#define REG_HCS		0x30
#define REG_HCE		0x34
#define REG_UTRLBA	0x50
#define REG_UTRLBAU	0x54
#define REG_UTRLDBR	0x58
#define REG_UTRLCLR	0x5c
#define REG_UTRLRSR	0x60

#define HCS_DP		(1u << 0)
#define HCS_UTRLRDY	(1u << 1)

#define BLOCK		4096u
#define XFER_BLOCKS	64u		/* one PRDT entry of 256 KiB */

static inline uint32_t ufs_rd(uint32_t off) { return *(volatile uint32_t *)(UFS_BASE + off); }
static inline void ufs_wr(uint32_t off, uint32_t v) { *(volatile uint32_t *)(UFS_BASE + off) = v; }

struct utrd {
	uint32_t dw0, dw1, dw2, dw3;
	uint32_t ucdba, ucdbau;
	uint32_t resp;		/* [31:16] response UPIU offset, [15:0] length (DWORDs) */
	uint32_t prdt;		/* [31:16] PRDT offset (DWORDs), [15:0] entries */
};

struct ucd {
	uint8_t cmd[512];
	uint8_t resp[512];
	struct {
		uint32_t addr_lo, addr_hi, rsvd, dbc;
	} prdt[1];
};

static struct utrd utrl[32] __attribute__((aligned(1024)));
static struct ucd ucd __attribute__((aligned(128)));
static uint8_t data[XFER_BLOCKS * BLOCK] __attribute__((aligned(4096)));

static int ready;
static uint64_t part_first, part_blocks;	/* userdata, in 4K blocks */
static uint64_t scratch_first;

static uint64_t ticks(void)
{
	uint64_t t;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	return t;
}

/*
 * One SCSI command in slot 0. dir: 0 none, 1 data out (to the device),
 * 2 data in. Returns 0 on success, else the failing stage.
 */
static uint32_t scsi(const uint8_t *cdb, unsigned cdb_len, void *buf, uint32_t len, int dir)
{
	static uint8_t tag;
	uint8_t *u = (uint8_t *)&utrl[0];
	for (unsigned i = 0; i < sizeof(utrl[0]); i++)
		u[i] = 0;
	vzero(&ucd, sizeof(ucd));

	ucd.cmd[0] = 0x01;				/* COMMAND UPIU */
	ucd.cmd[1] = dir == 1 ? 0x20 : dir == 2 ? 0x40 : 0;	/* W / R flag */
	ucd.cmd[2] = 0;					/* LUN 0 */
	ucd.cmd[3] = ++tag;
	ucd.cmd[12] = len >> 24;
	ucd.cmd[13] = len >> 16;
	ucd.cmd[14] = len >> 8;
	ucd.cmd[15] = len;
	for (unsigned i = 0; i < cdb_len; i++)
		ucd.cmd[16 + i] = cdb[i];

	uintptr_t ucd_pa = (uintptr_t)&ucd;
	/* CT=UFS storage, DD 1 = memory to device, 2 = device to memory, I */
	utrl[0].dw0 = (1u << 28) | ((uint32_t)dir << 25) | (1u << 24);
	utrl[0].dw2 = 0x0f;
	utrl[0].ucdba = (uint32_t)ucd_pa;
	utrl[0].ucdbau = (uint32_t)(ucd_pa >> 32);
	utrl[0].resp = (512u / 4) << 16 | (512u / 4);
	if (len) {
		uintptr_t buf_pa = (uintptr_t)buf;
		ucd.prdt[0].addr_lo = (uint32_t)buf_pa;
		ucd.prdt[0].addr_hi = (uint32_t)(buf_pa >> 32);
		ucd.prdt[0].dbc = len - 1;
		utrl[0].prdt = (1024u / 4) << 16 | 1;
	}
	__asm__ volatile("dsb sy" ::: "memory");

	ufs_wr(REG_UTRLDBR, 1);
	uint64_t start = ticks();
	while (ufs_rd(REG_UTRLDBR) & 1) {
		if (ticks() - start > 19200000ULL * 5) {	/* 5 s */
			ufs_wr(REG_UTRLCLR, ~1u);
			return 1;
		}
	}
	__asm__ volatile("dsb sy" ::: "memory");
	ufs_wr(REG_IS, ufs_rd(REG_IS));
	if (utrl[0].dw2 & 0xff)
		return 0x100 | (utrl[0].dw2 & 0xff);	/* OCS */
	if (ucd.resp[0] != 0x21)
		return 3;
	if (ucd.resp[6] || ucd.resp[7])
		return 0x200 | ucd.resp[6] << 8 | ucd.resp[7];
	return 0;
}

static uint32_t read_blocks(uint64_t lba, uint32_t count, void *buf)
{
	uint8_t cdb[10] = { 0x28, 0, lba >> 24, lba >> 16, lba >> 8, lba, 0, count >> 8, count, 0 };
	return scsi(cdb, sizeof(cdb), buf, count * BLOCK, 2);
}

static uint64_t le64(const uint8_t *p)
{
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--)
		v = v << 8 | p[i];
	return v;
}

static uint32_t le32(const uint8_t *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static int find_userdata(void)
{
	if (read_blocks(1, 1, data))
		return -1;
	static const char sig[] = "EFI PART";
	for (int i = 0; i < 8; i++)
		if (data[i] != (uint8_t)sig[i])
			return -2;
	uint64_t entry_lba = le64(data + 72);
	uint32_t nent = le32(data + 80), esz = le32(data + 84);
	if (esz != 128 || nent == 0 || nent * esz > sizeof(data))
		return -3;
	if (read_blocks(entry_lba, (nent * esz + BLOCK - 1) / BLOCK, data))
		return -4;
	static const char want[] = "userdata";
	for (uint32_t i = 0; i < nent; i++) {
		const uint8_t *e = data + i * esz;
		int match = 1;
		for (int c = 0; c < 9; c++)
			if (e[56 + 2 * c] != (uint8_t)want[c] || e[57 + 2 * c])
				match = 0;
		if (!match)
			continue;
		part_first = le64(e + 32);
		part_blocks = le64(e + 40) - part_first + 1;
		return 0;
	}
	return -5;
}

int ufs_init(void)
{
	uint32_t cap = ufs_rd(REG_CAP), hcs = ufs_rd(REG_HCS), hce = ufs_rd(REG_HCE);
	log_printf("ufs: ver=%x cap=%x hce=%x hcs=%x is=%x rsr=%x dbr=%x utrlba=%x:%x\n",
		   ufs_rd(REG_VER), cap, hce, hcs, ufs_rd(REG_IS), ufs_rd(REG_UTRLRSR),
		   ufs_rd(REG_UTRLDBR), ufs_rd(REG_UTRLBAU), ufs_rd(REG_UTRLBA));
	if (!(hce & 1) || !(hcs & HCS_DP) || !(hcs & HCS_UTRLRDY)) {
		log_printf("ufs: host not enabled/ready\n");
		return -1;
	}
	if (ufs_rd(REG_UTRLDBR)) {
		log_printf("ufs: requests outstanding\n");
		return -1;
	}
	ufs_wr(REG_UTRLRSR, 0);
	uintptr_t list = (uintptr_t)utrl;
	ufs_wr(REG_UTRLBA, (uint32_t)list);
	ufs_wr(REG_UTRLBAU, (uint32_t)(list >> 32));
	ufs_wr(REG_UTRLRSR, 1);
	/* Never ring a doorbell unless the host really uses our list. */
	if (ufs_rd(REG_UTRLBA) != (uint32_t)list || ufs_rd(REG_UTRLBAU) != (uint32_t)(list >> 32) ||
	    !(ufs_rd(REG_UTRLRSR) & 1)) {
		log_printf("ufs: list base not taken\n");
		return -1;
	}
	static const uint8_t tur[6] = { 0 };
	uint32_t rc = 0;
	for (int i = 0; i < 3; i++) {
		rc = scsi(tur, sizeof(tur), 0, 0, 0);
		if (!rc)
			break;
	}
	log_printf("ufs: test unit ready rc=%x\n", rc);
	int prc = find_userdata();
	if (prc) {
		log_printf("ufs: userdata not found (%d)\n", prc);
		return -1;
	}
	if (part_blocks < UFS_SCRATCH_TAIL + UFS_RESCUE_BLOCKS + 16) {
		log_printf("ufs: userdata too small\n");
		return -1;
	}
	scratch_first = part_first + part_blocks - UFS_SCRATCH_TAIL;
	ready = 1;
	log_printf("ufs: userdata first=%lx blocks=%lx scratch=%lx+%x\n",
		   part_first, part_blocks, scratch_first, UFS_SCRATCH_BLOCKS);
	return 0;
}

/*
 * Read count blocks starting at block index idx of the scratch area. Reads
 * may go on into the XNU log after it (idx up to UFS_SCRATCH_TAIL).
 */
int ufs_scratch_read(uint32_t idx, uint32_t count, void *buf)
{
	if (!ready || count > XFER_BLOCKS || idx >= UFS_SCRATCH_TAIL ||
	    count > UFS_SCRATCH_TAIL - idx)
		return -1;
	uint32_t rc = read_blocks(scratch_first + idx, count, data);
	if (rc)
		return -(int)rc;
	vcopy(buf, data, count * BLOCK);
	return 0;
}

static int write_lba(uint64_t lba, uint32_t count, const void *buf);

/* Write count blocks to the scratch area, then flush the device cache. */
int ufs_scratch_write(uint32_t idx, uint32_t count, const void *buf)
{
	if (!ready || count == 0 || count > XFER_BLOCKS || idx >= UFS_SCRATCH_BLOCKS ||
	    count > UFS_SCRATCH_BLOCKS - idx)
		return -1;
	return write_lba(scratch_first + idx, count, buf);
}

/* Write count blocks to the rescue area just below the scratch area. */
int ufs_rescue_write(uint32_t idx, uint32_t count, const void *buf)
{
	if (!ready || count == 0 || count > XFER_BLOCKS || idx >= UFS_RESCUE_BLOCKS ||
	    count > UFS_RESCUE_BLOCKS - idx)
		return -1;
	return write_lba(scratch_first - UFS_RESCUE_BLOCKS + idx, count, buf);
}

static int write_lba(uint64_t lba, uint32_t count, const void *buf)
{
	if (lba < part_first || lba + count > part_first + part_blocks)
		return -1;
	vcopy(data, buf, count * BLOCK);
	uint8_t cdb[10] = { 0x2a, 0, lba >> 24, lba >> 16, lba >> 8, lba, 0, count >> 8, count, 0 };
	uint32_t rc = scsi(cdb, sizeof(cdb), data, count * BLOCK, 1);
	if (rc)
		return -(int)rc;
	static const uint8_t sync[10] = { 0x35 };
	rc = scsi(sync, sizeof(sync), 0, 0, 0);
	return rc ? -(int)rc : 0;
}
