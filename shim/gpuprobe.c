/*
 * GPU probe mode (built with -DSHIM_GPUPROBE): first step of Adreno 640
 * bring-up. Powers only the GPU's CX side (no GMU firmware, no GX rail):
 *
 *   GCC   gpu_cfg_ahb, ddrss_gpu_axi, gpu_memnoc_gfx, gpu_snoc_dvm_gfx
 *   GPUCC CX GDSC on, gmu_clk_src = XO (19.2 MHz), ahb, cxo, cx_gmu clocks
 *
 * then reads GMU registers, checks that the GMU's ITCM takes writes, and
 * reads the Adreno SMMU's ID registers (does the hypervisor let us at it?).
 * Offsets: mainline gcc/gpucc-sm8150.c, a6xx_gmu.xml (dword offsets from
 * the GPU base 0x2c00000), sm8150.dtsi.
 *
 * Stage 2 (gmu_boot) follows a6xx_gmu.c's cold boot for the A640: an Adreno
 * SMMU context bank with our own page tables for the GMU stream (id 5, mask
 * 0x400), the RSC/PDC sequencer setup, firmware blocks into ITCM/DTCM and the
 * icache/dcache windows (GMU VA 0x4000 / 0x44000), HFI queue table, then
 * CM3 reset release and a poll for the firmware's init result.
 */
#ifdef SHIM_GPUPROBE
#include <stdint.h>
#include "gpuprobe.h"
#include "log.h"
#include "util.h"

#define GCC		0x00100000UL
#define GPUCC		0x02c90000UL
#define GPU		0x02c00000UL
#define GMU_REG(o)	(GPU + 4UL * (o))
#define SMMU		0x02ca0000UL

#define GPUCC_CX_GDSCR	0x106c
#define GPUCC_GX_GDSCR	0x100c
#define GPUCC_GMU_RCG	0x1120
#define GPUCC_AHB	0x1078
#define GPUCC_CXO	0x109c
#define GPUCC_CX_GMU	0x1098

#define GMU_ITCM	0x1b400
#define GMU_DTCM	0x1c400
#define GMU_FW_VERSION	0x1d3f8
#define GMU_INIT_RESULT	0x1f81c
#define GMU_RPMH_STATE	0x1f8ec
#define GMU_GENERAL_7	0x1f9cc
#define GMU_CX_BUSY	0x23b0c

static int wait_bit(uintptr_t reg, uint32_t mask, int set, unsigned ms)
{
	for (unsigned i = 0; i <= ms; i++) {
		if (!!(rd32(reg) & mask) == set)
			return 0;
		delay_ms(1);
	}
	return -1;
}

static void branch_on(const char *name, uintptr_t reg)
{
	wr32(reg, rd32(reg) | 1);
	int rc = wait_bit(reg, 1u << 31, 0, 10);
	log_printf("gpu: %s %lx = %x%s\n", name, (uint64_t)reg, rd32(reg), rc ? " (still halted)" : "");
}

/*
 * A hung bus access (unclocked block) stalls the CPU for good: the caller
 * arms the watchdog, and the log is saved before each risky stage so the
 * last "stage" line says where it stopped.
 */
static void gmu_boot(void (*save)(const char *));
static void gmu_hfi(void (*save)(const char *), int cb);
static void zap_load(void (*save)(const char *));
static void gpu_run(void (*save)(const char *), int gmu_cb);

void gpuprobe_run(void (*save)(const char *))
{
	log_printf("gpu: before cx_gdsc %x gx_gdsc %x gmu_rcg %x/%x ahb %x cxo %x cx_gmu %x\n",
		   rd32(GPUCC + GPUCC_CX_GDSCR), rd32(GPUCC + GPUCC_GX_GDSCR),
		   rd32(GPUCC + GPUCC_GMU_RCG), rd32(GPUCC + GPUCC_GMU_RCG + 4),
		   rd32(GPUCC + GPUCC_AHB), rd32(GPUCC + GPUCC_CXO), rd32(GPUCC + GPUCC_CX_GMU));
	log_printf("gpu: gcc cfg_ahb %x axi %x memnoc %x snoc_dvm %x\n", rd32(GCC + 0x71004),
		   rd32(GCC + 0x71154), rd32(GCC + 0x7100c), rd32(GCC + 0x71018));

	save("gpu: before gcc");
	branch_on("gcc gpu_cfg_ahb", GCC + 0x71004);
	branch_on("gcc ddrss_gpu_axi", GCC + 0x71154);
	branch_on("gcc gpu_memnoc_gfx", GCC + 0x7100c);
	branch_on("gcc gpu_snoc_dvm_gfx", GCC + 0x71018);

	save("gpu: before cx gdsc");
	/* CX GDSC: clear SW_COLLAPSE (bit 0), wait for PWR_ON (bit 31). */
	uintptr_t gdsc = GPUCC + GPUCC_CX_GDSCR;
	wr32(gdsc, rd32(gdsc) & ~1u);
	int rc = wait_bit(gdsc, 1u << 31, 1, 100);
	log_printf("gpu: cx gdsc -> %x %s\n", rd32(gdsc), rc ? "TIMEOUT" : "on");

	/* gmu_clk_src: source 0 (XO), divider 1 (HID 1), then update. */
	uintptr_t rcg = GPUCC + GPUCC_GMU_RCG;
	wr32(rcg + 4, (rd32(rcg + 4) & ~0x71fu) | 1u);
	wr32(rcg, rd32(rcg) | 1u);
	rc = wait_bit(rcg, 1, 0, 10);
	log_printf("gpu: gmu rcg %x cfg %x %s\n", rd32(rcg), rd32(rcg + 4), rc ? "UPDATE TIMEOUT" : "");

	branch_on("gpucc ahb", GPUCC + GPUCC_AHB);
	branch_on("gpucc cxo", GPUCC + GPUCC_CXO);
	branch_on("gpucc cx_gmu", GPUCC + GPUCC_CX_GMU);

	save("gpu: before gmu reads");
	log_printf("gpu: gmu fw_version %x init_result %x rpmh_state %x general_7 %x cx_busy %x\n",
		   rd32(GMU_REG(GMU_FW_VERSION)), rd32(GMU_REG(GMU_INIT_RESULT)),
		   rd32(GMU_REG(GMU_RPMH_STATE)), rd32(GMU_REG(GMU_GENERAL_7)),
		   rd32(GMU_REG(GMU_CX_BUSY)));

	save("gpu: before tcm test");
	/* ITCM/DTCM write test: proves the GMU's memories are reachable. */
	uintptr_t itcm = GMU_REG(GMU_ITCM), dtcm = GMU_REG(GMU_DTCM);
	uint32_t i0 = rd32(itcm), d0 = rd32(dtcm);
	wr32(itcm, 0x464c414d);
	wr32(dtcm, 0x45475055);
	log_printf("gpu: itcm %x -> %x, dtcm %x -> %x (want 464c414d 45475055)\n",
		   i0, rd32(itcm), d0, rd32(dtcm));

	save("gpu: before smmu");
	log_printf("gpu: smmu cr0 %x idr0 %x idr1 %x idr2 %x idr7 %x\n", rd32(SMMU + 0x0),
		   rd32(SMMU + 0x20), rd32(SMMU + 0x24), rd32(SMMU + 0x28), rd32(SMMU + 0x3c));

	gmu_boot(save);
}

/* ---- stage 2: GMU boot ---- */

#define SMMU_GR1	(SMMU + 0x1000)
#define SMMU_CB(n)	(SMMU + 0x8000 + 0x1000UL * (n))
#define SMR(n)		(SMMU + 0x800 + 4 * (n))
#define S2CR(n)		(SMMU + 0xc00 + 4 * (n))
#define CBAR(n)		(SMMU_GR1 + 4 * (n))
#define CBA2R(n)	(SMMU_GR1 + 0x800 + 4 * (n))
#define CB_SCTLR	0x00
#define CB_TCR2		0x10
#define CB_TTBR0	0x20
#define CB_TCR		0x30
#define CB_MAIR0	0x38
#define CB_FSR		0x58
#define CB_FAR		0x60
#define CB_FSYNR0	0x68

#define GMU_SID		5
#define GMU_SID_MASK	0x400

/* Memory for page tables and GMU buffers: high DRAM the shim never uses. */
#define GMEM		0x1f0000000UL
#define GMEM_L1		(GMEM + 0x0000)
#define GMEM_L2_0	(GMEM + 0x1000)		/* VA 0x00000000-0x3fffffff */
#define GMEM_L2_1	(GMEM + 0x2000)		/* VA 0x40000000-0x7fffffff */
#define GMEM_L3_LOW	(GMEM + 0x3000)		/* VA 0x00000000-0x001fffff */
#define GMEM_L3_6	(GMEM + 0x4000)		/* VA 0x60000000-0x601fffff */
#define GMEM_ICACHE	(GMEM + 0x10000)
#define GMEM_DCACHE	(GMEM + 0x50000)
#define GMEM_DUMMY	(GMEM + 0x90000)
#define GMEM_LOG	(GMEM + 0x91000)
#define GMEM_HFI	(GMEM + 0x95000)
#define GMEM_SIZE	0x100000UL

#define VA_ICACHE	0x4000u
#define VA_DCACHE	0x44000u
#define CACHE_SIZE	0x3c000u
#define VA_DUMMY	0x60000000u
#define VA_LOG		0x60001000u
#define VA_HFI		0x60005000u

#define RSCC		(0x02c6a000UL + 0x23000)	/* a6xx_gmu.c: gmu->mmio + 0x23000 before A650 */
#define RSCC_REG(o)	(RSCC + 4UL * (o))
#define PDC		0x0b290000UL
#define PDC_REG(o)	(PDC + 4UL * (o))
#define PDC_SEQ		0x0b490000UL

#define GMU_SYSRESET	0x1f800
#define GMU_BOOT_CFG	0x1f801
#define GMU_CM3_CFG	0x1f82d
#define GMU_PWRCOL_CTRL	0x1f8c0
#define GMU_RPMH_CTRL	0x1f8e8
#define GMU_CP_MSG	0x1f900
#define GMU_CP_RESP	0x1f901
#define GMU_HFI_CTRL	0x1f980
#define GMU_SFR_ADDR	0x1f982
#define GMU_QTBL_INFO	0x1f984
#define GMU_QTBL_ADDR	0x1f985
#define GMU_SYS_BUS	0x1f40f
#define GMU_ICACHE_CFG	0x1f400
#define GMU_DCACHE_CFG	0x1f401
#define GMU_RSCC_REQ	0x23b07
#define GMU_RSCC_ACK	0x23b08
#define GMU_FENCE0	0x23b11

extern const uint8_t gmu_fw[], gmu_fw_end[];

static void zero32(uintptr_t pa, uint64_t size)
{
	for (uint64_t o = 0; o < size; o += 4)
		wr32(pa + o, 0);
}

static void wr64(uintptr_t pa, uint64_t v)
{
	wr32(pa, (uint32_t)v);
	wr32(pa + 4, (uint32_t)(v >> 32));
}

/*
 * Stage-1 AArch64 4K page: AF, inner shareable, AttrIndx 0 (NC). priv: AP=00
 * (privileged RW, executable by the GMU, like Linux's IOMMU_PRIV for the
 * icache/dcache windows); otherwise AP=01, which makes a page EL0-writable
 * and so never privileged-executable (probe 2 faulted fetching at 0x4dc0).
 */
static void map_pages(uintptr_t l3, uint32_t va, uintptr_t pa, uint32_t size, int priv)
{
	for (uint32_t o = 0; o < size; o += 0x1000) {
		uint32_t idx = ((va + o) >> 12) & 0x1ff;
		wr64(l3 + 8 * idx, (pa + o) | (1u << 10) | (3u << 8) | (priv ? 0 : (1u << 6)) | 3u);
	}
}

static int smmu_setup(void)
{
	int smr = -1, cb = -1;
	uint32_t used_cb = 0;
	for (int i = 0; i < 6; i++) {
		uint32_t m = rd32(SMR(i)), c = rd32(S2CR(i));
		log_printf("smmu: smr%d %x s2cr %x\n", i, m, c);
		if ((m >> 31) && ((c >> 16) & 3) == 0)
			used_cb |= 1u << (c & 0xff);
		if (smr < 0 && !(m >> 31))
			smr = i;
	}
	for (int i = 0; i < 5; i++) {
		log_printf("smmu: cb%d cbar %x cba2r %x sctlr %x ttbr0 %x:%x\n", i, rd32(CBAR(i)),
			   rd32(CBA2R(i)), rd32(SMMU_CB(i) + CB_SCTLR), rd32(SMMU_CB(i) + CB_TTBR0 + 4),
			   rd32(SMMU_CB(i) + CB_TTBR0));
		if (cb < 0 && !(used_cb & (1u << i)) && !(rd32(SMMU_CB(i) + CB_SCTLR) & 1))
			cb = i;
	}
	log_printf("smmu: using smr %d cb %d\n", smr, cb);
	if (smr < 0 || cb < 0)
		return -1;

	zero32(GMEM, GMEM_SIZE);
	wr64(GMEM_L1 + 0, GMEM_L2_0 | 3);
	wr64(GMEM_L1 + 8, GMEM_L2_1 | 3);
	wr64(GMEM_L2_0 + 0, GMEM_L3_LOW | 3);
	wr64(GMEM_L2_1 + 8 * ((VA_DUMMY >> 21) & 0x1ff), GMEM_L3_6 | 3);
	map_pages(GMEM_L3_LOW, VA_ICACHE, GMEM_ICACHE, CACHE_SIZE, 1);
	map_pages(GMEM_L3_LOW, VA_DCACHE, GMEM_DCACHE, CACHE_SIZE, 1);
	map_pages(GMEM_L3_6, VA_DUMMY, GMEM_DUMMY, 0x1000, 0);
	map_pages(GMEM_L3_6, VA_LOG, GMEM_LOG, 0x4000, 0);
	map_pages(GMEM_L3_6, VA_HFI, GMEM_HFI, 0x4000, 0);

	uintptr_t c = SMMU_CB(cb);
	wr32(c + CB_SCTLR, 0);
	wr32(CBA2R(cb), 1);					/* AArch64 descriptors */
	wr32(CBAR(cb), (1u << 16) | (0xfu << 12) | (3u << 8) | (cb + 1));	/* S1, S2 bypass, VMID */
	wr32(c + CB_TCR2, 2);					/* 40-bit PA */
	wr64(c + CB_TTBR0, GMEM_L1);
	wr32(c + CB_TCR, 32 | (1u << 8) | (1u << 10) | (3u << 12) | (1u << 23));
	wr32(c + CB_MAIR0, 0x0000ff44);
	wr32(c + CB_FSR, 0xffffffff);
	wr32(c + CB_SCTLR, 1 | 2 | 4 | 0x20 | 0x40);		/* M TRE AFE CFRE CFIE */
	wr32(SMMU + 0x68, 0);					/* TLBIALLNSNH */
	wr32(SMMU + 0x70, 0);					/* TLBGSYNC */
	wait_bit(SMMU + 0x74, 1, 0, 10);
	wr32(S2CR(smr), cb);					/* translate via cb */
	wr32(SMR(smr), (1u << 31) | (GMU_SID_MASK << 16) | GMU_SID);
	log_printf("smmu: now smr%d %x s2cr %x cbar %x cba2r %x sctlr %x tcr %x ttbr0 %x:%x\n", smr,
		   rd32(SMR(smr)), rd32(S2CR(smr)), rd32(CBAR(cb)), rd32(CBA2R(cb)),
		   rd32(c + CB_SCTLR), rd32(c + CB_TCR), rd32(c + CB_TTBR0 + 4), rd32(c + CB_TTBR0));
	return cb;
}

/* a6xx_gmu_rpmh_init for the A640 (pdc_address_offset 0x30090). */
static void rpmh_init(void (*save)(const char *))
{
	log_printf("gmu: rscc status0 %x seq_busy %x\\n", rd32(RSCC_REG(0x0004)), rd32(RSCC_REG(0x0101)));
	save("gmu: rscc readable");
	wr32(RSCC_REG(0x0004), 1u << 24);
	wr32(RSCC_REG(0x000b), 1);
	wr32(RSCC_REG(0x000e), 0);
	wr32(RSCC_REG(0x000d), 0);
	wr32(RSCC_REG(0x000e + 2), 0);
	wr32(RSCC_REG(0x000d + 2), 0);
	wr32(RSCC_REG(0x000e + 4), 0x80000000);
	wr32(RSCC_REG(0x000d + 4), 0);
	wr32(RSCC_REG(0x0100), 0);
	wr32(RSCC_REG(0x0008), 0x4520);
	wr32(RSCC_REG(0x0009), 0x4510);
	wr32(RSCC_REG(0x000a), 0x4514);
	wr32(RSCC_REG(0x0180), 0xa7a506a0);
	wr32(RSCC_REG(0x0181), 0xa1e6a6e7);
	wr32(RSCC_REG(0x0182), 0xa2e081e1);
	wr32(RSCC_REG(0x0183), 0xe9a982e2);
	wr32(RSCC_REG(0x0184), 0x0020e8a8);

	save("gmu: rscc programmed");
	log_printf("gmu: pdc enable %x\\n", rd32(PDC_REG(0x1140)));
	save("gmu: pdc readable");
	wr32(PDC_SEQ + 0, 0xfebea1e1);
	wr32(PDC_SEQ + 4, 0xa5a4a3a2);
	wr32(PDC_SEQ + 8, 0x8382a6e0);
	wr32(PDC_SEQ + 12, 0xbce3e284);
	wr32(PDC_SEQ + 16, 0x002081fc);

	wr32(PDC_REG(0x1573), 7);
	wr32(PDC_REG(0x1574), 0);
	wr32(PDC_REG(0x1572), 0);
	wr32(PDC_REG(0x1575), 0x10108);
	wr32(PDC_REG(0x1576), 0x30010);
	wr32(PDC_REG(0x1577), 1);
	wr32(PDC_REG(0x1575 + 4), 0x10108);
	wr32(PDC_REG(0x1576 + 4), 0x30000);
	wr32(PDC_REG(0x1577 + 4), 0);
	wr32(PDC_REG(0x1575 + 8), 0x10108);
	wr32(PDC_REG(0x1576 + 8), 0x30090);
	wr32(PDC_REG(0x1577 + 8), 0);

	wr32(PDC_REG(0x15d7), 7);
	wr32(PDC_REG(0x15d8), 0);
	wr32(PDC_REG(0x15d6), 0);
	wr32(PDC_REG(0x15d9), 0x10108);
	wr32(PDC_REG(0x15da), 0x30010);
	wr32(PDC_REG(0x15db), 2);
	wr32(PDC_REG(0x15d9 + 4), 0x10108);
	wr32(PDC_REG(0x15da + 4), 0x30000);
	wr32(PDC_REG(0x15db + 4), 3);
	wr32(PDC_REG(0x15d9 + 8), 0x10108);
	wr32(PDC_REG(0x15da + 8), 0x30090);
	wr32(PDC_REG(0x15db + 8), 3);

	wr32(PDC_REG(0x1148), 0);
	wr32(PDC_REG(0x1140), 0x80000001);
}

static void hfi_table(void)
{
	/* Table header (6 dwords), then 3 queue headers (12 dwords each). */
	uintptr_t t = GMEM_HFI;
	wr32(t + 0, 0);
	wr32(t + 4, 6 * 4 + 3 * 12 * 4);
	wr32(t + 8, 6);
	wr32(t + 12, 12);
	wr32(t + 16, 3);
	wr32(t + 20, 3);
	for (int q = 0; q < 3; q++) {
		uintptr_t h = t + 24 + 48 * q;
		wr32(h + 0, 1);					/* status */
		wr32(h + 4, VA_HFI + 0x1000 * (q + 1));		/* iova */
		wr32(h + 8, (10u << 8) | (uint32_t)q);		/* type: ids 0 1 2 */
		wr32(h + 12, 0x1000 >> 2);
		wr32(h + 24, 1);
		wr32(h + 28, 1);
		wr32(h + 32, 1);
	}
}

static int fw_load(void)
{
	const uint8_t *p = gmu_fw;
	int n = 0;
	while (p + 16 <= gmu_fw_end) {
		uint32_t addr, size;
		__builtin_memcpy(&addr, p, 4);
		__builtin_memcpy(&size, p + 4, 4);
		const uint8_t *data = p + 16;
		uintptr_t dst = 0;
		if (addr < 0x4000)
			dst = GMU_REG(GMU_ITCM) + addr;
		else if (addr >= 0x40000 && addr < 0x44000)
			dst = GMU_REG(GMU_DTCM) + (addr - 0x40000);
		else if (addr >= VA_ICACHE && addr + size <= VA_ICACHE + CACHE_SIZE)
			dst = GMEM_ICACHE + (addr - VA_ICACHE);
		else if (addr >= VA_DCACHE && addr + size <= VA_DCACHE + CACHE_SIZE)
			dst = GMEM_DCACHE + (addr - VA_DCACHE);
		log_printf("gmu fw: block %x size %x -> %lx\n", addr, size, (uint64_t)dst);
		if (!dst)
			return -1;
		for (uint32_t o = 0; o < size; o += 4) {
			uint32_t w;
			__builtin_memcpy(&w, data + o, 4);
			wr32(dst + o, w);
		}
		p = data + size;
		n++;
	}
	return n;
}

static void gmu_boot(void (*save)(const char *))
{
	save("gmu: before smmu setup");
	int cb = smmu_setup();
	save("gmu: smmu set up");
	if (cb < 0)
		return;
	rpmh_init(save);
	hfi_table();
	save("gmu: rpmh/hfi set up");

	wr32(GMU_REG(GMU_GENERAL_7), 1);
	wr32(GMU_REG(GMU_RSCC_REQ), 1u << 1);
	int rc = wait_bit(GMU_REG(GMU_RSCC_ACK), 1u << 1, 1, 200);
	int rc2 = wait_bit(RSCC_REG(0x0101), 0xffffffff, 0, 10);
	wr32(GMU_REG(GMU_RSCC_REQ), 0);
	log_printf("gmu: rsc wake ack %s seq %s (ack %x busy %x rsc status0 %x pdc enable %x)\n",
		   rc ? "TIMEOUT" : "ok", rc2 ? "BUSY" : "idle", rd32(GMU_REG(GMU_RSCC_ACK)),
		   rd32(RSCC_REG(0x0101)), rd32(RSCC_REG(0x0004)), rd32(PDC_REG(0x1140)));
	save("gmu: rsc started");

	int nblk = fw_load();
	log_printf("gmu: %d firmware blocks loaded, fw version reg %x\n", nblk,
		   rd32(GMU_REG(GMU_FW_VERSION)));
	save("gmu: fw loaded");
	if (nblk <= 0)
		return;

	wr32(GMU_REG(GMU_INIT_RESULT), 0);
	wr32(GMU_REG(GMU_BOOT_CFG), 2);
	wr32(GMU_REG(GMU_QTBL_ADDR), VA_HFI);
	wr32(GMU_REG(GMU_QTBL_INFO), 1);
	wr32(GMU_REG(GMU_FENCE0), (1u << 31) | (0xau << 18) | 0xa0);
	wr32(GMU_REG(GMU_CM3_CFG), 0x4052);
	wr32(GMU_REG(GMU_SFR_ADDR), 0x06040100);		/* GMU-style chip id of 640.1 */
	for (int i = 0; i < 4; i++)				/* a640_gbif (gbif_cx) */
		wr32(GPU + 4 * (0x3c03 + i), 0x00071620);
	wr32(GMU_REG(GMU_CP_MSG), VA_LOG | (0x4000 / 0x1000 - 1));
	/* a6xx_gmu_power_config: no IFPC, RPMh interface + votes on */
	wr32(GMU_REG(GMU_SYS_BUS), 1);
	wr32(GMU_REG(GMU_ICACHE_CFG), 1);
	wr32(GMU_REG(GMU_DCACHE_CFG), 1);
	wr32(GMU_REG(GMU_PWRCOL_CTRL), 0x9c40400);
	wr32(GMU_REG(GMU_RPMH_CTRL), rd32(GMU_REG(GMU_RPMH_CTRL)) |
	     1 | (1u << 4) | (1u << 8) | (1u << 9) | (1u << 10) | (1u << 11));

	uint32_t v = rd32(GMU_REG(GMU_DTCM) + 0xff8 * 4);
	uint32_t mask = v <= 0x20010004 ? 0xffffffff : 0x1ff;
	uint32_t want = v <= 0x20010004 ? 0xbabeface : 0x100;
	log_printf("gmu: dtcm[0xff8] %x -> waiting for init result %x/%x\n", v, want, mask);
	save("gmu: starting cm3");
	wr32(GMU_REG(GMU_SYSRESET), 1);
	wr32(GMU_REG(GMU_CP_RESP), 0);
	wr32(GMU_REG(GMU_SYSRESET), 0);
	uint32_t r = 0;
	int ok = 0;
	for (int i = 0; i < 2000; i++) {
		r = rd32(GMU_REG(GMU_INIT_RESULT));
		if ((r & mask) == want) {
			ok = 1;
			break;
		}
		delay_ms(1);
	}
	uintptr_t c = SMMU_CB(cb);
	log_printf("gmu: init result %x %s, hfi_ctrl %x, cb fsr %x far %x:%x fsynr0 %x\n", r,
		   ok ? "BOOTED" : "timeout", rd32(GMU_REG(GMU_HFI_CTRL)), rd32(c + CB_FSR),
		   rd32(c + CB_FAR + 4), rd32(c + CB_FAR), rd32(c + CB_FSYNR0));
	log_printf("gmu: log[0..3] %x %x %x %x, gfsr %x\n", rd32(GMEM_LOG), rd32(GMEM_LOG + 4),
		   rd32(GMEM_LOG + 8), rd32(GMEM_LOG + 12), rd32(SMMU + 0x48));
	if (ok)
		gmu_hfi(save, cb);
}

/* ---- stage 3: HFI messages, GPU power-up ---- */

#define GMU_G2H_CLR	0x1f991
#define GMU_G2H_INFO	0x1f992
#define GMU_H2G_SET	0x1f994
#define HFI_Q_CMD	0
#define HFI_Q_RESP	1
#define QHDR(q)		(GMEM_HFI + 24 + 48 * (q))
#define QDATA(q)	(GMEM_HFI + 0x1000 * ((q) + 1))
#define QSIZE		1024		/* dwords */

/* RPMh regulator levels (dt-bindings qcom-rpmpd.h). */
#define LVL_MIN_SVS	48
#define LVL_LOW_SVS	64
#define LVL_SVS		128
#define LVL_SVS_L1	192
#define LVL_SVS_L2	224
#define LVL_NOM		256

/* GPU OPPs every sm8150 speed bin supports (sm8150.dtsi), "off" first. */
static const uint32_t gpu_khz[] = { 0, 257000, 345000, 427000, 499200, 585000 };
static const uint32_t gpu_lvl[] = { 0, LVL_LOW_SVS, LVL_SVS, LVL_SVS_L1, LVL_SVS_L2, LVL_NOM };
static const uint32_t gmu_khz[] = { 0, 200000 };
static const uint32_t gmu_lvl[] = { 0, LVL_MIN_SVS };

static uint32_t hfi_seq;

/* cmd-db aux data (an array of u16 levels) for an id such as "gfx.lvl". */
static int cmddb_aux(const char *id, uintptr_t *aux, uint32_t *len)
{
	uintptr_t db = rd32(0x0c3f000cUL);
	if (rd32(db + 4) != 0x0c0330db)
		return -1;
	uintptr_t data = db + 4 + 4 + 8 * 16 + 4 + 4;
	for (int r = 0; r < 8; r++) {
		uintptr_t rh = db + 8 + 16 * r;
		uint32_t w0 = rd32(rh), w1 = rd32(rh + 4);
		uint32_t hoff = w0 >> 16, doff = w1 & 0xffff, cnt = w1 >> 16;
		for (uint32_t e = 0; e < cnt; e++) {
			uintptr_t ent = data + hoff + 24 * e;
			char name[9];
			for (int i = 0; i < 8; i++)
				name[i] = (char)(rd32(ent + (i & ~3)) >> (8 * (i & 3)));
			name[8] = 0;
			int match = 1;
			for (int i = 0; i < 8; i++) {
				if (name[i] != id[i]) {
					match = 0;
					break;
				}
				if (!id[i])
					break;
			}
			if (!match)
				continue;
			uint32_t w5 = rd32(ent + 20);
			*len = w5 & 0xffff;
			*aux = data + doff + (w5 >> 16);
			return 0;
		}
	}
	return -1;
}

static uint32_t aux16(uintptr_t aux, uint32_t i)
{
	return (rd32(aux + 2 * (i & ~1u)) >> (16 * (i & 1))) & 0xffff;
}

/* a6xx_gmu_rpmh_arc_votes_init */
static int arc_votes(uint32_t *votes, const uint32_t *lvl, int n, const char *pri_id, const char *sec_id)
{
	uintptr_t pri, sec;
	uint32_t plen, slen;
	if (cmddb_aux(pri_id, &pri, &plen) || cmddb_aux(sec_id, &sec, &slen))
		return -1;
	plen /= 2;
	slen /= 2;
	log_printf("cmddb: %s %u levels, %s %u levels:", pri_id, plen, sec_id, slen);
	for (uint32_t j = 0; j < plen; j++)
		log_printf(" %u", aux16(pri, j));
	log_printf("\n");
	for (int i = 0; i < n; i++) {
		uint32_t pindex = 0, sindex = 0, j;
		for (j = 0; j < plen; j++)
			if (aux16(pri, j) >= lvl[i]) {
				pindex = j;
				break;
			}
		if (j == plen)
			return -1;
		for (j = 0; j < slen; j++) {
			if (aux16(sec, j) >= lvl[i]) {
				sindex = j;
				break;
			} else if (aux16(sec, j)) {
				sindex = j;
			}
		}
		votes[i] = (aux16(pri, pindex) << 16) | (sindex << 8) | pindex;
	}
	return 0;
}

static int hfi_send(uint32_t id, uint32_t *msg, uint32_t dwords, uint32_t *resp_out)
{
	uint32_t seq = ++hfi_seq;
	msg[0] = (seq << 20) | (0u << 16) | (dwords << 8) | id;
	uintptr_t h = QHDR(HFI_Q_CMD);
	uint32_t w = rd32(h + 44);
	for (uint32_t i = 0; i < dwords; i++) {
		wr32(QDATA(HFI_Q_CMD) + 4 * w, msg[i]);
		w = (w + 1) % QSIZE;
	}
	for (; w % 4; w = (w + 1) % QSIZE)
		wr32(QDATA(HFI_Q_CMD) + 4 * w, 0xfafafafa);
	__asm__ volatile("dsb sy" ::: "memory");
	wr32(h + 44, w);
	wr32(GMU_REG(GMU_H2G_SET), 1);

	for (int t = 0; t < 1000; t++) {
		if (rd32(GMU_REG(GMU_G2H_INFO)) & 1) {
			wr32(GMU_REG(GMU_G2H_CLR), 1);
			uintptr_t rh = QHDR(HFI_Q_RESP);
			while (rd32(rh + 40) != rd32(rh + 44)) {
				uint32_t r = rd32(rh + 40), hdr = rd32(QDATA(HFI_Q_RESP) + 4 * r);
				uint32_t n = (hdr >> 8) & 0xff, buf[24] = { 0 };
				for (uint32_t i = 0; i < n && i < 24; i++) {
					buf[i] = rd32(QDATA(HFI_Q_RESP) + 4 * r);
					r = (r + 1) % QSIZE;
				}
				r = ((r + 3) & ~3u) % QSIZE;
				wr32(rh + 40, r);
				log_printf("hfi: <- id %u size %u seq %u: %x %x %x %x\n", hdr & 0xff, n,
					   buf[1] >> 20, buf[1], buf[2], buf[3], buf[4]);
				/* a6xx_hfi_wait_for_ack: matched by the seqnum in ret_header */
				if ((hdr & 0xff) != 100 && (buf[1] >> 20) == seq) {
					if (resp_out)
						for (int i = 0; i < 4; i++)
							resp_out[i] = buf[3 + i];
					return (int)buf[2];	/* error code, 0 = ok */
				}
			}
		}
		delay_ms(1);
	}
	log_printf("hfi: msg %u seq %u: no ack (info %x)\n", id, seq, rd32(GMU_REG(GMU_G2H_INFO)));
	return -1;
}

static void gmu_hfi(void (*save)(const char *), int cb)
{
	static uint32_t msg[256];
	uint32_t gx[6], cx[2];
	if (arc_votes(gx, gpu_lvl, 6, "gfx.lvl", "mx.lvl") ||
	    arc_votes(cx, gmu_lvl, 2, "cx.lvl", "mx.lvl")) {
		log_printf("hfi: cmd-db levels not found\n");
		return;
	}
	save("hfi: votes built");

	/* perf table: header, num gpu, num gmu, gx[16] {vote, acd, freq}, cx[4] {vote, freq} */
	for (int i = 0; i < 256; i++)
		msg[i] = 0;
	msg[1] = 6;
	msg[2] = 2;
	for (int i = 0; i < 6; i++) {
		msg[3 + 3 * i] = gx[i];
		msg[4 + 3 * i] = 0xffffffff;
		msg[5 + 3 * i] = gpu_khz[i];
	}
	for (int i = 0; i < 2; i++) {
		msg[3 + 48 + 2 * i] = cx[i];
		msg[4 + 48 + 2 * i] = gmu_khz[i];
	}
	int rc = hfi_send(4, msg, 3 + 48 + 8, 0);
	log_printf("hfi: perf table (gx %x %x .. %x) -> %d\n", gx[0], gx[1], gx[5], rc);
	save("hfi: perf table");

	/* bw table, a640_build_bw_table */
	for (int i = 0; i < 256; i++)
		msg[i] = 0;
	msg[1] = 1;
	msg[2] = 3;			/* cnoc cmds */
	msg[3] = 3;			/* ddr cmds */
	msg[4] = 1;
	msg[5] = 1;
	msg[6] = 0x50034;		/* cnoc addrs [6] at 6..11 */
	msg[7] = 0x5007c;
	msg[8] = 0x5004c;
	msg[12] = 0x40000000;		/* cnoc data [2][6] at 12..23 */
	msg[13] = 0x00000000;
	msg[14] = 0x40000000;
	msg[18] = 0x60000001;
	msg[19] = 0x20000001;
	msg[20] = 0x60000001;
	msg[24] = 0x50000;		/* ddr addrs [8] at 24..31 */
	msg[25] = 0x5003c;
	msg[26] = 0x5000c;
	msg[32] = 0x40000000;		/* ddr data [16][8] at 32.. */
	msg[33] = 0x40000000;
	msg[34] = 0x40000000;
	rc = hfi_send(3, msg, 32 + 128, 0);
	log_printf("hfi: bw table -> %d\n", rc);
	save("hfi: bw table");

	msg[1] = 0;
	rc = hfi_send(14, msg, 2, 0);
	log_printf("hfi: core fw start -> %d\n", rc);
	rc = hfi_send(10, msg, 1, 0);
	log_printf("hfi: start -> %d\n", rc);
	save("hfi: started");

	/* perf vote: GX_BW_PERF_VOTE {ack_type 1, freq index, bw index} */
	msg[1] = 1;
	msg[2] = 1;			/* 257 MHz */
	msg[3] = 0;
	rc = hfi_send(30, msg, 4, 0);
	log_printf("hfi: perf vote 257 MHz -> %d\n", rc);
	save("hfi: perf vote");

	/* OOB GPU_SET (non-legacy bits 30/31): the GMU powers the GX side. */
	wr32(GMU_REG(GMU_H2G_SET), 1u << 30);
	int ack = wait_bit(GMU_REG(GMU_G2H_INFO), 1u << 31, 1, 1000);
	wr32(GMU_REG(GMU_G2H_CLR), 1u << 31);
	log_printf("gpu: oob gpu_set %s (info %x), gx gdsc %x, rpmh state %x, rsc status0 %x\n",
		   ack ? "TIMEOUT" : "acked", rd32(GMU_REG(GMU_G2H_INFO)), rd32(GPUCC + GPUCC_GX_GDSCR),
		   rd32(GMU_REG(GMU_RPMH_STATE)), rd32(RSCC_REG(0x0004)));
	log_printf("gmu: log %x %x %x %x %x %x %x %x\n", rd32(GMEM_LOG + 16), rd32(GMEM_LOG + 20),
		   rd32(GMEM_LOG + 24), rd32(GMEM_LOG + 28), rd32(GMEM_LOG + 32), rd32(GMEM_LOG + 36),
		   rd32(GMEM_LOG + 40), rd32(GMEM_LOG + 44));
	save("gpu: oob gpu_set");

	if (!(rd32(GPUCC + GPUCC_GX_GDSCR) & (1u << 31))) {
		log_printf("gpu: GX not powered; not touching GPU registers\n");
		return;
	}
	/* RBBM_STATUS (0x210) and CP_SCRATCH_REG0 (0x883) write/read test. */
	log_printf("gpu: rbbm_status %x\n", rd32(GPU + 4 * 0x210));
	wr32(GPU + 4 * 0x883, 0x41445245);
	log_printf("gpu: cp_scratch0 -> %x (want 41445245)\n", rd32(GPU + 4 * 0x883));
	log_printf("gmu: cb fsr %x\n", rd32(SMMU_CB(cb) + CB_FSR));
	gpu_run(save, cb);	/* loads the zap shader after CP_ME_INIT, like a6xx hw_init */
}

/* ---- stage 4: zap shader through TrustZone PAS (qcom_scm + mdt_loader) ---- */

#define PAS_GPU		13
#define ZAP_REGION	0x9a915000UL	/* reserved-memory pil_gpu_region, 8K */
#define ZAP_SIZE	0x2000UL
#define ZAP_META	(GMEM + 0xa0000)	/* metadata buffer TZ reads */
#define SCM_PIL(cmd)	(0x42000000UL | (2u << 8) | (cmd))	/* SMC64 std call, SIP, svc PIL */

extern const uint8_t zap_mdt[], zap_mdt_end[], zap_b02[], zap_b02_end[];

static int64_t scm(uint32_t cmd, uint64_t arginfo, uint64_t a, uint64_t b, uint64_t c, uint64_t *r1)
{
	uint64_t x1 = 0;
	uint64_t r = smc_call5(SCM_PIL(cmd), arginfo, a, b, c, 0, &x1);
	if (r1)
		*r1 = x1;
	return (int64_t)r;
}

static void copy_in(uintptr_t dst, const uint8_t *src, uint32_t len)
{
	for (uint32_t o = 0; o < len; o += 4) {
		uint32_t w = 0;
		for (uint32_t i = 0; i < 4 && o + i < len; i++)
			w |= (uint32_t)src[o + i] << (8 * i);
		wr32(dst + o, w);
	}
}

static void zap_load(void (*save)(const char *))
{
	uint64_t r1 = 0;
	int64_t rc = scm(7, 1, PAS_GPU, 0, 0, &r1);		/* PAS_IS_SUPPORTED */
	log_printf("zap: pas supported(13) rc %ld r1 %lx\n", (long)rc, r1);
	save("zap: pas supported");

	uint32_t mlen = (uint32_t)(zap_mdt_end - zap_mdt);
	copy_in(ZAP_META, zap_mdt, mlen);
	__asm__ volatile("dsb sy" ::: "memory");
	/* INIT_IMAGE(peripheral, metadata PA): QCOM_SCM_ARGS(2, VAL, RW) */
	rc = scm(1, 2 | (2u << 6), PAS_GPU, ZAP_META, 0, &r1);
	log_printf("zap: init image (%u bytes metadata) rc %ld r1 %lx\n", mlen, (long)rc, r1);
	save("zap: init image");
	if (rc || r1)
		return;

	rc = scm(2, 3, PAS_GPU, ZAP_REGION, ZAP_SIZE, &r1);	/* MEM_SETUP */
	log_printf("zap: mem setup rc %ld r1 %lx\n", (long)rc, r1);
	save("zap: mem setup");
	if (rc || r1)
		return;

	/* Relocatable: the one LOAD segment (paddr 0x5000, the lowest) at the region base. */
	uint32_t slen = (uint32_t)(zap_b02_end - zap_b02);
	for (uint32_t o = 0; o < ZAP_SIZE; o += 4)
		wr32(ZAP_REGION + o, 0);
	copy_in(ZAP_REGION, zap_b02, slen);
	__asm__ volatile("dsb sy" ::: "memory");
	save("zap: segment copied");

	rc = scm(5, 1, PAS_GPU, 0, 0, &r1);			/* AUTH_AND_RESET */
	log_printf("zap: auth and reset rc %ld r1 %lx\n", (long)rc, r1);
	save("zap: auth and reset");
}


/* ---- stage 5: SQE, ringbuffer, first commands ---- */

#define GREG(o)		(GPU + 4UL * (o))
#define GPU_SID		0
#define GPU_SID_MASK	0x401
#define GT_L1		(GMEM + 0x200000)
#define GT_L2		(GMEM + 0x201000)
#define GT_L3		(GMEM + 0x202000)	/* VA 0x10000000-0x101fffff */
#define G_SQE		(GMEM + 0x300000)
#define G_RING		(GMEM + 0x310000)
#define G_TARGET	(GMEM + 0x320000)
#define GVA_SQE		0x10000000u
#define GVA_RING	0x10010000u
#define GVA_TARGET	0x10020000u
#define RING_DW		(0x8000 / 4)

extern const uint8_t sqe_fw[], sqe_fw_end[];
static uint32_t wptr;

static uint32_t pm4_parity(uint32_t v)
{
	return (0x9669 >> (0xf & (v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^
				   (v >> 20) ^ (v >> 24) ^ (v >> 28)))) & 1;
}

static void ring(uint32_t v)
{
	wr32(G_RING + 4 * wptr, v);
	wptr = (wptr + 1) % RING_DW;
}

static void pkt7(uint32_t op, uint32_t cnt)
{
	ring(0x70000000 | cnt | (pm4_parity(cnt) << 15) | ((op & 0x7f) << 16) |
	     (pm4_parity(op) << 23));
}

static int flush_wait(const char *what)
{
	__asm__ volatile("dsb sy" ::: "memory");
	wr32(GREG(0x807), wptr);			/* CP_RB_WPTR */
	int i;
	for (i = 0; i < 1000; i++) {
		if (rd32(GREG(0x806)) == wptr && !(rd32(GREG(0x210)) & (1u << 23)))
			break;
		delay_ms(1);
	}
	log_printf("gpu: %s: rptr %x wptr %x status %x int %x hwfault %x cp_status1 %x %s\n", what,
		   rd32(GREG(0x806)), wptr, rd32(GREG(0x210)), rd32(GREG(0x201)), rd32(GREG(0x821)),
		   rd32(GREG(0x825)), i < 1000 ? "idle" : "TIMEOUT");
	return i < 1000 ? 0 : -1;
}

#define GVA_FB		0x20000000u
#define FB_PA		0x9c400000UL
#define FB_STRIDE	4320
#define BAND_Y		700
#define BAND_H		600

/*
 * Visible proof: map the panel framebuffer into the GPU and let the GPU
 * paint a band: one gradient row by CP_MEM_WRITE, then CP_MEMCPY copies it
 * down BAND_H rows. The CPU never touches the framebuffer here.
 */
static void gpu_paint(void (*save)(const char *), uintptr_t c)
{
	for (int i = 0; i < 5; i++)	/* 10 MB as 2 MB blocks, AP=01, NC */
		wr64(GT_L2 + 8 * (((GVA_FB >> 21) & 0x1ff) + i),
		     (FB_PA + 0x200000UL * i) | (1u << 10) | (3u << 8) | (1u << 6) | 1u);
	wr32(c + 0x618, 0);		/* CB TLBIALL */
	wr32(c + 0x7f0, 0);		/* CB TLBSYNC */
	wait_bit(c + 0x7f4, 1, 0, 10);

	uint32_t row = GVA_FB + BAND_Y * FB_STRIDE;
	pkt7(0x3d, 2 + 1080);		/* CP_MEM_WRITE one row */
	ring(row);
	ring(0);
	for (uint32_t x = 0; x < 1080; x++) {
		uint32_t r = x * 255 / 1079, b = 255 - r, g = (x / 60) % 2 ? 200 : 40;
		ring(0xff000000 | (r << 16) | (g << 8) | b);
	}
	pkt7(0x26, 0);
	flush_wait("paint row");
	for (uint32_t y = 1; y < BAND_H; y++) {
		pkt7(0x75, 5);		/* CP_MEMCPY dwords, src, dst */
		ring(1080);
		ring(row);
		ring(0);
		ring(row + y * FB_STRIDE);
		ring(0);
		if ((y % 100) == 0)
			flush_wait("paint copy");
	}
	pkt7(0x26, 0);
	flush_wait("paint done");
	log_printf("gpu: painted %d rows at y %d; fb word %x\n", BAND_H, BAND_Y,
		   rd32(FB_PA + (BAND_Y + BAND_H / 2) * FB_STRIDE + 540 * 4));
	save("gpu: painted");
	delay_ms(8000);		/* for the camera; the watchdog bites at 20 s */
}

static void gpu_run(void (*save)(const char *), int gmu_cb)
{
	int cb = gmu_cb + 1, smr = -1;
	for (int i = 0; i < 6; i++)
		if (!(rd32(SMR(i)) >> 31)) {
			smr = i;
			break;
		}
	if (smr < 0 || cb >= 5)
		return;

	/* GPU page tables: AP=01 (unprivileged, as Linux maps GPU buffers). */
	zero32(GT_L1, 0x3000);
	zero32(G_SQE, 0x21000);
	wr64(GT_L1 + 0, GT_L2 | 3);
	wr64(GT_L2 + 8 * ((GVA_SQE >> 21) & 0x1ff), GT_L3 | 3);
	map_pages(GT_L3, GVA_SQE, G_SQE, 0x10000, 0);
	map_pages(GT_L3, GVA_RING, G_RING, 0x8000, 0);
	map_pages(GT_L3, GVA_TARGET, G_TARGET, 0x1000, 0);
	wr32(G_TARGET, 0x11111111);

	uintptr_t c = SMMU_CB(cb);
	wr32(c + CB_SCTLR, 0);
	wr32(CBA2R(cb), 1);
	wr32(CBAR(cb), (1u << 16) | (0xfu << 12) | (3u << 8) | (cb + 1));
	wr32(c + CB_TCR2, 2);
	wr64(c + CB_TTBR0, GT_L1);
	wr32(c + CB_TCR, 32 | (1u << 8) | (1u << 10) | (3u << 12) | (1u << 23));
	wr32(c + CB_MAIR0, 0x0000ff44);
	wr32(c + CB_FSR, 0xffffffff);
	wr32(c + CB_SCTLR, 1 | 2 | 4 | 0x20 | 0x40);
	wr32(SMMU + 0x68, 0);
	wr32(SMMU + 0x70, 0);
	wait_bit(SMMU + 0x74, 1, 0, 10);
	wr32(S2CR(smr), (uint32_t)cb);
	wr32(SMR(smr), (1u << 31) | (GPU_SID_MASK << 16) | GPU_SID);
	log_printf("gpu: smmu smr%d %x -> cb%d\n", smr, rd32(SMR(smr)), cb);
	save("gpu: smmu set up");

	/* hw_init subset for the A640 (a6xx_gpu.c) */
	wr32(GREG(0x3c45), 0);			/* GBIF_HALT */
	(void)rd32(GREG(0x3c45));
	wr32(GREG(0x16), 0);			/* RBBM_GBIF_HALT */
	(void)rd32(GREG(0x16));
	wr32(GREG(0xf803), 0);			/* RBBM_SECVID_TSB_CNTL */
	wr32(GREG(0xf800), 0);
	wr32(GREG(0xf801), 0);
	wr32(GREG(0xf802), 0);
	static const uint16_t addr_mode[] = { 0x0842, 0x0c01, 0x8601, 0x8e05, 0x9e01, 0xbe05,
					      0xa601, 0x9601, 0x0e00, 0xae01, 0xb601, 0xf810 };
	for (unsigned i = 0; i < sizeof(addr_mode) / sizeof(addr_mode[0]); i++)
		wr32(GREG(addr_mode[i]), 1);
	wr32(GREG(0x11), 3);			/* RBBM_GBIF_CLIENT_QOS_CNTL */
	wr32(GREG(0x50b), 0xffffffff);
	uint64_t trap = 0x1fffffffff000ull;
	wr32(GREG(0xe05), (uint32_t)(trap + 0xfc0));
	wr32(GREG(0xe06), (uint32_t)((trap + 0xfc0) >> 32));
	wr32(GREG(0xe09), (uint32_t)trap);
	wr32(GREG(0xe0a), (uint32_t)(trap >> 32));
	wr32(GREG(0xe07), (uint32_t)trap);
	wr32(GREG(0xe08), (uint32_t)(trap >> 32));
	wr32(GREG(0xe0b), 0x100000);		/* GMEM range 1M..2M-1 */
	wr32(GREG(0xe0c), 0);
	wr32(GREG(0xe0d), 0x1fffff);
	wr32(GREG(0xe0e), 0);
	wr32(GREG(0xe18), 0x804);
	wr32(GREG(0xe17), 0x4);
	wr32(GREG(0x8c2), 0x02000140);
	wr32(GREG(0x8c1), 0x8040362c);
	wr32(GREG(0x8c3), 128);
	wr32(GREG(0x98d), 1);			/* CP_AHB_CNTL */
	wr32(GREG(0x500), 1);
	wr32(GREG(0x1f), (1u << 30) | 0x1fffff);
	wr32(GREG(0xe19), (1u << 7) | 1);

	/* SQE microcode: the file minus its first dword. */
	uint32_t sqe_len = (uint32_t)(sqe_fw_end - sqe_fw) - 4;
	copy_in(G_SQE, sqe_fw + 4, sqe_len);
	wr32(GREG(0x830), GVA_SQE);		/* CP_SQE_INSTR_BASE (A6xx; 0x816 is A8xx) */
	wr32(GREG(0x831), 0);
	wr32(GREG(0x800), GVA_RING);
	wr32(GREG(0x801), 0);
	wr32(GREG(0x802), 0x0800020c);		/* 32K ring, 32-byte blocks, no rptr update */
	wptr = 0;
	log_printf("gpu: readback sqe base %x:%x rb base %x:%x rb cntl %x scratch %x gbif_halt %x secvid %x\n",
		   rd32(GREG(0x831)), rd32(GREG(0x830)), rd32(GREG(0x801)), rd32(GREG(0x800)),
		   rd32(GREG(0x802)), rd32(GREG(0x883)), rd32(GREG(0x3c45)), rd32(GREG(0xf803)));
	wr32(GREG(0x808), 1);			/* CP_SQE_CNTL: start the CP */
	log_printf("gpu: sqe %u bytes at %x, cp started, status %x\n", sqe_len, GVA_SQE,
		   rd32(GREG(0x210)));
	save("gpu: cp started");

	pkt7(0x48, 8);				/* CP_ME_INIT */
	ring(0x2f);
	ring(3);
	ring(0x20000000);
	for (int i = 0; i < 5; i++)
		ring(0);
	int rc = flush_wait("me_init");
	save("gpu: me_init");
	if (rc)
		goto out;

	zap_load(save);

	pkt7(0x66, 1);				/* CP_SET_SECURE_MODE 0 */
	ring(0);
	rc = flush_wait("secure mode off");
	save("gpu: secure mode off");
	if (rc)
		goto out;

	pkt7(0x3d, 3);				/* CP_MEM_WRITE */
	ring(GVA_TARGET);
	ring(0);
	ring(0xcafef00d);
	pkt7(0x26, 0);				/* CP_WAIT_FOR_IDLE */
	flush_wait("mem write");
	for (int i = 0; i < 100 && rd32(G_TARGET) != 0xcafef00d; i++)
		delay_ms(1);
	log_printf("gpu: target memory = %x %s\n", rd32(G_TARGET),
		   rd32(G_TARGET) == 0xcafef00d ? "*** GPU EXECUTED OUR COMMANDS ***" : "(unchanged)");
	if (rd32(G_TARGET) == 0xcafef00d)
		gpu_paint(save, c);
out:
	log_printf("gpu: cb%d fsr %x far %x:%x fsynr0 %x\n", cb, rd32(c + CB_FSR), rd32(c + CB_FAR + 4),
		   rd32(c + CB_FAR), rd32(c + CB_FSYNR0));
	save("gpu: done");
}
#endif /* SHIM_GPUPROBE */
