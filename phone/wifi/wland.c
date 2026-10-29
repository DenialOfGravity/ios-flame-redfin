/*
 * wland: WLAN bring-up for the Pixel 4 from userland (/dev/pmem), the way
 * the GPU was brought up: the modem DSP hosts the WLAN firmware (icnss /
 * WCN3990 family), so: power votes, PAS-boot the modem, SMP2P, then GLINK +
 * QRTR + QMI to the WLFW service, then the WLAN copy engines for WMI.
 *
 *   wland smem              SMEM partitions and the items we care about
 *   wland smp2p             modem SMP2P state (in: 435, out: 428)
 *   wland vote RES LVL      RPMh ARC level vote (index) for RES (e.g. mss.lvl)
 *   wland levels RES        cmd-db levels of an ARC resource
 *   wland bcm RES X [Y]     RPMh BCM (bus bandwidth) vote, e.g. MC0 (DDR) / SH0 (memory NoC); 0x3fff = top
 *   wland smp2p-init        our outbound SMP2P item + doorbell; shows the modem's entries
 *   wland qmp MSG           message to the AOP over QMP (opens the link if needed)
 *   wland shutdown          PAS shutdown of the modem
 *   wland boot              power votes + PAS boot of the modem + wait for ready
 *   wland smmu              the WLAN DMA stream through a translation-off SMMU bank (radio.c)
 *   wland up [SECS]         all of it from a fresh boot, then the radio: copy engines, WMI, passive scans
 *   wland auto              the boot job (launchd org.iosonpixel.wland): `up 0` once per phone boot, log in
 *                           /var/local/wland.log (last boot's: .prev); off with /var/local/wland.off or sweetwifi=0
 * While joined, SIGUSR1 drops the link (tests the rejoin).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include "pmem.h"
#include "ipcc.h"
#include "smem.h"
#include "link.h"
#include "rmtfs.h"
#include "pdmapper.h"
#include "tftp.h"
#include "wlfw.h"
#include "radio.h"
#include "ipnet.h"
#include "bridge.h"

/* cmd-db aux levels (as in the GPU's arc votes) */
/* Every cmd-db entry: name, RPMh slave (3 ARC, 4 VRM, 5 BCM), address. */
static void cmddb_list(void)
{
	uint64_t db = rd32(0x0c3f000cull);
	if (rd32(db + 4) != 0x0c0330db)
		return;
	uint64_t data = db + 4 + 4 + 8 * 16 + 4 + 4;
	for (uint32_t r = 0; r < 8; r++) {
		uint64_t rh = db + 8 + 16 * r;
		uint32_t w0 = rd32(rh), w1 = rd32(rh + 4);
		uint32_t hoff = w0 >> 16, cnt = w1 >> 16;
		for (uint32_t e = 0; e < cnt; e++) {
			uint64_t ent = data + hoff + 24 * e;
			char name[9];
			for (uint32_t i = 0; i < 8; i++)
				name[i] = (char)(rd32(ent + (i & ~3u)) >> (8 * (i & 3)));
			name[8] = 0;
			printf("%-8s slave %u addr %05x\n", name, w0 & 0xffff, rd32(ent + 16));
		}
	}
}

static int cmddb_aux(const char *id, uint64_t *aux, uint32_t *len)
{
	uint64_t db = rd32(0x0c3f000cull);
	if (rd32(db + 4) != 0x0c0330db)
		return -1;
	uint64_t data = db + 4 + 4 + 8 * 16 + 4 + 4;
	for (uint32_t r = 0; r < 8; r++) {
		uint64_t rh = db + 8 + 16 * r;
		uint32_t w0 = rd32(rh), w1 = rd32(rh + 4);
		uint32_t hoff = w0 >> 16, doff = w1 & 0xffff, cnt = w1 >> 16;
		for (uint32_t e = 0; e < cnt; e++) {
			uint64_t ent = data + hoff + 24 * e;
			char name[9];
			for (uint32_t i = 0; i < 8; i++)
				name[i] = (char)(rd32(ent + (i & ~3u)) >> (8 * (i & 3)));
			name[8] = 0;
			if (strncmp(name, id, 8))
				continue;
			uint32_t w5 = rd32(ent + 20);
			*len = w5 & 0xffff;
			*aux = data + doff + (w5 >> 16);
			return 0;
		}
	}
	return -1;
}

static uint32_t aux16(uint64_t aux, uint32_t i)
{
	return (rd32(aux + 2 * (i & ~1u)) >> (16 * (i & 1))) & 0xffff;
}

static int levels(const char *res, int print)
{
	uint64_t aux;
	uint32_t len;
	if (cmddb_aux(res, &aux, &len)) {
		fprintf(stderr, "%s: not in cmd-db\n", res);
		return -1;
	}
	if (print) {
		printf("%s:", res);
		for (uint32_t i = 0; i < len / 2; i++)
			printf(" [%u]=%u", i, aux16(aux, i));
		printf("\n");
	}
	return (int)(len / 2);
}

static int vote(const char *res, uint32_t level_index)
{
	uint32_t off[1] = { 0 }, val[1] = { level_index };
	int rc = pm_rpmh(res, 1, off, val);
	printf("vote %s level index %u -> %d\n", res, level_index, rc);
	return rc;
}

/*
 * The WLAN supplies (icnss in the stock DT: vdd-cx-mx, vdd-1.8-xo, vdd-1.3-rfa, vdd-3.3-ch0), RPMh VRM
 * votes as Linux qcom-rpmh-regulator: voltage (mV) at 0, enable at 4, mode at 8 (PMIC5 LDO HPM = 7).
 * Without them the WLAN firmware takes an exception once calibration starts (after the cal report).
 */
static int qmp_send(const char *msg);

static int wlan_power(void)
{
	/*
	 * redfin (lito.dtsi icnss) rails in the driver's order (icnss_vreg_info): cx-mx L1A (DT
	 * cx-mx-config <0 0>: enable only, no voltage), 1.8-xo L14A, 1.3-rfa L2C, 3.3-ch1 L11C,
	 * 3.3-ch0 L10C, both 3312 mV. (sunfish: L9A 640, L1C, L2C, L11C, L10C.)
	 * mv 0 = enable + mode only.
	 * /var/local/wlan-rails.conf ("ldoXN MV" per line) replaces the table for experiments.
	 */
	static struct { char res[16]; uint32_t mv; } ldo[8] = {
		{ "ldoa1", 0 }, { "ldoa14", 1800 }, { "ldoc2", 1304 }, { "ldoc11", 3312 }, { "ldoc10", 3312 },
	};
	unsigned nldo = 5;
	FILE *rf = fopen("/var/local/wlan-rails.conf", "r");
	if (rf) {
		char res[16];
		unsigned mv;
		nldo = 0;
		while (nldo < 8 && fscanf(rf, "%15s %u", res, &mv) == 2) {
			snprintf(ldo[nldo].res, sizeof(ldo[nldo].res), "%s", res);
			ldo[nldo++].mv = mv;
		}
		fclose(rf);
		printf("wlan power: %u rails from /var/local/wlan-rails.conf\n", nldo);
	}
	for (unsigned i = 0; i < nldo; i++) {
		uint32_t off[3] = { 0, 8, 4 }, val[3] = { ldo[i].mv, 7, 1 };
		int rc = ldo[i].mv ? pm_rpmh(ldo[i].res, 3, off, val) : pm_rpmh(ldo[i].res, 2, off + 1, val + 1);
		printf("wlan power: %s %u mV on -> %d\n", ldo[i].res, ldo[i].mv, rc);
		if (rc)
			return -1;
	}
	/*
	 * The WCN399x reference clock. sunfish/sm8150 (mainline: clocks = <&rpmhcc RPMH_RF_CLK2>,
	 * "cxo_ref_clk_pin") need the rfclka2 VRM vote; redfin's icnss node has no clocks and lito's
	 * cmd-db has no rfclka2 (log 2026-10-24: "lookup matches=0"), so the vote is only made when
	 * cmd-db has the resource. /var/local/wlan-rfclk names another resource to vote instead.
	 */
	char clk[16] = "rfclka2";
	FILE *cf = fopen("/var/local/wlan-rfclk", "r");
	if (cf) {
		if (fscanf(cf, "%15s", clk) != 1)
			snprintf(clk, sizeof(clk), "rfclka2");
		fclose(cf);
	}
	uint64_t aux;
	uint32_t alen;
	if (cmddb_aux(clk, &aux, &alen)) {
		printf("wlan power: %s not in cmd-db: no RF clock vote (redfin icnss has no clocks); cmd-db:\n", clk);
		cmddb_list();
	} else {
		uint32_t off[1] = { 4 }, val[1] = { 1 };
		int rc = pm_rpmh(clk, 1, off, val);
		printf("wlan power: %s on -> %d\n", clk, rc);
		if (rc)
			return -1;
	}
	/* mainline sm8150 wifi: clocks "cxo_ref_clk_pin", "qdss" = <&aoss_qmp>: the QDSS clock is an AOSS
	 * message. Trace clock only: a failure is logged, not fatal. */
	if (qmp_send("{class: clock, res: qdss, val: 1}"))
		printf("wlan power: qdss clock message failed (continuing)\n");
	return 0;
}

/* SMP2P item: magic "$SMP", version/features, local/remote pid, total/valid entries, flags, entries[16+4] */
static void smp2p_show(const char *what, unsigned item)
{
	uint64_t pa;
	uint32_t sz;
	if (smem_get(SMEM_HOST_MODEM, item, &pa, &sz)) {
		printf("smp2p %s (item %u): absent\n", what, item);
		return;
	}
	uint32_t w1 = rd32(pa + 4), pids = rd32(pa + 8), counts = rd32(pa + 12);
	printf("smp2p %s (item %u) at %llx: magic %08x ver %u feat %x pids %u->%u entries %u/%u flags %x\n", what, item,
	       (unsigned long long)pa, rd32(pa), w1 & 0xff, w1 >> 8, pids & 0xffff, pids >> 16, counts >> 16,
	       counts & 0xffff, rd32(pa + 16));
	for (uint32_t i = 0; i < (counts >> 16) && i < 16; i++) {
		uint64_t e = pa + 20 + 20ull * i;
		char name[17];
		for (int k = 0; k < 16; k++)
			name[k] = (char)(rd32(e + (k & ~3)) >> (8 * (k & 3)));
		name[16] = 0;
		printf("  entry %u: %-16s value %08x\n", i, name, rd32(e + 16));
	}
}

/* ---- SMP2P outbound (Linux qcom_smp2p_alloc_outbound_item) and the IPCC doorbell (ipcc.h) ---- */

#define IPC_MODEM_SMP2P	DB_MODEM_SMP2P
#define IPC_MODEM_GLINK	DB_MODEM_GLINK
#define SMP2P_OUT	428	/* lito-smp2p.dtsi qcom,smp2p-mpss qcom,smem = <435>, <428> */
#define SMP2P_IN	435

static void kick(uint32_t id)
{
	wr32(IPCC_SEND_ID, id);
}

static void wr_name(uint64_t pa, const char *name)
{
	char n[16] = { 0 };
	strncpy(n, name, sizeof(n));
	for (int i = 0; i < 16; i += 4) {
		uint32_t w;
		memcpy(&w, n + i, 4);
		wr32(pa + i, w);
	}
}

static uint64_t smp2p_out_pa;

/* Our outbound item (Linux allocates it at probe, before the modem boots: the modem needs it). */
static int smp2p_create(void)
{
	uint64_t pa;
	if (smem_alloc(SMEM_HOST_MODEM, SMP2P_OUT, 20 + 16 * 20, &pa)) {
		fprintf(stderr, "smp2p: cannot allocate item %u\n", SMP2P_OUT);
		return -1;
	}
	if (rd32(pa) != 0x504d5324) {
		wr32(pa + 8, 0 | (1u << 16));		/* local pid 0, remote pid 1 */
		wr32(pa + 12, 16 | (1u << 16));		/* total 16 entries, 1 valid */
		wr32(pa + 16, 0);			/* flags */
		wr_name(pa + 20, "master-kernel");
		wr32(pa + 36, 0);
		wr32(pa + 0, 0x504d5324);		/* "$SMP" */
		__asm__ volatile("dsb sy" ::: "memory");
		wr32(pa + 4, 1 | (1u << 8));		/* version 1 last, features: SSR ack */
	}
	smp2p_out_pa = pa;
	kick(IPC_MODEM_SMP2P);
	return 0;
}

/* Address of the value of the modem's inbound entry NAME (0 = found). */
static int smp2p_in_entry(const char *name, uint64_t *va)
{
	uint64_t pa;
	uint32_t sz;
	if (smem_get(SMEM_HOST_MODEM, SMP2P_IN, &pa, &sz))
		return -1;
	uint32_t n = rd32(pa + 12) >> 16;
	for (uint32_t i = 0; i < n && i < 16; i++) {
		uint64_t e = pa + 20 + 20ull * i;
		char nm[17];
		for (int k = 0; k < 16; k++)
			nm[k] = (char)(rd32(e + (k & ~3)) >> (8 * (k & 3)));
		nm[16] = 0;
		if (!strcmp(nm, name)) {
			*va = e + 16;
			return 0;
		}
	}
	return -1;
}

static int smp2p_in_value(const char *name, uint32_t *v)
{
	uint64_t va;
	if (smp2p_in_entry(name, &va))
		return -1;
	*v = rd32(va);
	return 0;
}

/*
 * Keep the SMP2P side going: SSR ack (Linux qcom_smp2p_do_ssr_ack: after a
 * restart the modem flips RESTART_DONE, flags bit 0, and waits for the same
 * in our RESTART_ACK, bit 1), and report changes of the modem's state bits
 * (slave-kernel: 0 err-fatal, 1 ready, 2 handover, 3 stop-ack).
 */
static uint32_t modem_state = 0xffffffff;
static void smp2p_service(void)
{
	uint64_t ip;
	uint32_t sz, v;
	if (!smp2p_out_pa && smem_get(SMEM_HOST_MODEM, SMP2P_OUT, &smp2p_out_pa, &sz))
		return;
	if (smem_get(SMEM_HOST_MODEM, SMP2P_IN, &ip, &sz) == 0) {
		uint32_t want = (rd32(ip + 16) & 1) ? 2 : 0;
		if ((rd32(smp2p_out_pa + 16) & 2) != want) {
			wr32(smp2p_out_pa + 16, (rd32(smp2p_out_pa + 16) & ~2u) | want);
			kick(IPC_MODEM_SMP2P);
			printf("smp2p: restart %s\n", want ? "acked" : "ack cleared");
		}
	}
	if (smp2p_in_value("slave-kernel", &v) == 0 && v != modem_state) {
		printf("[%6llu] smp2p: modem state %x%s%s%s%s\n", (unsigned long long)link_ms(), v, v & 1 ? " ERR-FATAL" : "", v & 2 ? " ready" : "",
		       v & 4 ? " handover" : "", v & 8 ? " stop-ack" : "");
		/* modem crash reason (Linux qcom_q6v5 SMEM_SSR_REASON_MSS0, global item 421), once */
		static int reason_shown;
		uint64_t rp;
		uint32_t rsz;
		if ((v & 1) && !reason_shown && smem_get(SMEM_HOST_GLOBAL, 421, &rp, &rsz) == 0 && rsz) {
			char r[256];
			uint32_t n = rsz < sizeof(r) - 1 ? rsz : sizeof(r) - 1;
			for (uint32_t i = 0; i < n; i++) {
				char c = (char)(rd32(rp + (i & ~3u)) >> (8 * (i & 3)));
				r[i] = (c >= 32 && c < 127) ? c : (c ? '.' : 0);
				if (!c) { n = i; break; }
			}
			r[n] = 0;
			printf("modem crash reason: \"%s\"\n", r);
			reason_shown = 1;
		}
		modem_state = v;
	}
}

static int smp2p_init(void)
{
	if (smp2p_create())
		return -1;
	printf("smp2p: outbound item %u at %llx ready, modem kicked\n", SMP2P_OUT, (unsigned long long)smp2p_out_pa);
	for (int t = 0; t < 50; t++) {
		smp2p_service();
		usleep(100000);
	}
	smp2p_show("in", SMP2P_IN);
	return 0;
}

/* ---- AOSS QMP (Linux qcom_aoss.c): messages to the always-on processor ---- */

#define QMP_RAM		0x0c300000ull
#define IPC_AOSS	DB_AOSS	/* lito qmp-aop@c300000: mboxes <&ipcc_mproc IPCC_CLIENT_AOP 0> */
#define QMP_UP		0x0000ffffu

static int wait_eq(uint64_t pa, uint32_t want, int ms)
{
	for (int i = 0; i < ms; i++) {
		if (rd32(pa) == want)
			return 0;
		usleep(1000);
	}
	return -1;
}

static int qmp_open(void)
{
	if (rd32(QMP_RAM) != 0x4d41494c || rd32(QMP_RAM + 4) != 1) {
		fprintf(stderr, "qmp: magic %08x version %u\n", rd32(QMP_RAM), rd32(QMP_RAM + 4));
		return -1;
	}
	if (rd32(QMP_RAM + 0x24) == QMP_UP && rd32(QMP_RAM + 0x2c) == QMP_UP && rd32(QMP_RAM + 0x30) == QMP_UP)
		return 0;	/* already open */
	wr32(QMP_RAM + 0x10, rd32(QMP_RAM + 0x0c));	/* ack ucore link state */
	wr32(QMP_RAM + 0x24, QMP_UP);			/* mcore link up */
	kick(IPC_AOSS);
	if (wait_eq(QMP_RAM + 0x28, QMP_UP, 1000)) {
		fprintf(stderr, "qmp: link not acked\n");
		return -1;
	}
	wr32(QMP_RAM + 0x2c, QMP_UP);			/* mcore channel up */
	kick(IPC_AOSS);
	if (wait_eq(QMP_RAM + 0x14, QMP_UP, 1000)) {
		fprintf(stderr, "qmp: ucore channel not up\n");
		return -1;
	}
	wr32(QMP_RAM + 0x18, QMP_UP);			/* ack ucore channel */
	kick(IPC_AOSS);
	if (wait_eq(QMP_RAM + 0x30, QMP_UP, 1000)) {
		fprintf(stderr, "qmp: mcore channel not acked\n");
		return -1;
	}
	return 0;
}

static int qmp_send(const char *msg)
{
	if (qmp_open())
		return -1;
	uint32_t off = rd32(QMP_RAM + 0x38), buf[16] = { 0 };
	strncpy((char *)buf, msg, sizeof(buf) - 1);
	for (int i = 0; i < 16; i++)
		wr32(QMP_RAM + off + 4 + 4 * i, buf[i]);
	wr32(QMP_RAM + off, sizeof(buf));
	(void)rd32(QMP_RAM + off);
	kick(IPC_AOSS);
	int rc = wait_eq(QMP_RAM + off, 0, 1000);
	printf("qmp: \"%s\" -> %s\n", msg, rc ? "TIMEOUT" : "acked");
	return rc;
}

/* ---- modem boot: TrustZone PAS (Linux qcom_q6v5_pas + qcom_mdt_loader) ---- */

#define PAS_MODEM	4
#define MPSS_PA		0x8c000000ull	/* redfin modem_wlan_mem (lito-redbull-memory.dtsi; sunfish 0x8b000000) */
#define MPSS_SIZE	0x11800000ull
#define FW_DIR		"/var/local/fw/modem"
#define SCM_PIL(cmd)	(0x42000000ull | (2u << 8) | (cmd))

static int64_t scm(uint32_t cmd, uint64_t arginfo, uint64_t a, uint64_t b, uint64_t c, uint64_t *r1)
{
	uint64_t x[8] = { SCM_PIL(cmd), arginfo, a, b, c, 0, 0, 0 };
	pm_smc(x);
	if (r1)
		*r1 = x[1];
	return (int64_t)x[0];
}

static uint8_t *slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	*len = (size_t)ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = malloc(*len + 1);
	if (b && fread(b, 1, *len, f) != *len) {
		free(b);
		b = NULL;
	}
	fclose(f);
	return b;
}

struct phdr { uint32_t type, offset, vaddr, paddr, filesz, memsz, flags, align; };

static int boot_modem(void)
{
	/* 1. proxy votes as downstream (vdd_cx/vdd_mss >= 385): the top levels */
	int ncx = levels("cx.lvl", 0), nmss = levels("mss.lvl", 0);
	uint64_t aux;
	uint32_t len, top_cx = 0, top_mss = 0;
	if (!cmddb_aux("cx.lvl", &aux, &len))
		for (uint32_t i = 0; i < len / 2; i++)
			if (aux16(aux, i))
				top_cx = i;
	if (!cmddb_aux("mss.lvl", &aux, &len))
		for (uint32_t i = 0; i < len / 2; i++)
			if (aux16(aux, i))
				top_mss = i;
	printf("boot: cx %d levels, mss %d levels: voting cx[%u] mss[%u]\n", ncx, nmss, top_cx, top_mss);
	if (vote("cx.lvl", top_cx) || vote("mss.lvl", top_mss))
		return -1;

	/* 2. metadata: ELF header + program headers + hash segment */
	size_t mlen;
	uint8_t *mdt = slurp(FW_DIR "/modem.mdt", &mlen);
	if (!mdt) {
		fprintf(stderr, "boot: no %s/modem.mdt\n", FW_DIR);
		return -1;
	}
	uint32_t phoff, phnum = 0;
	memcpy(&phoff, mdt + 0x1c, 4);
	memcpy(&phnum, mdt + 0x2c, 2);
	struct phdr *ph = (struct phdr *)(mdt + phoff);
	int hash = -1;
	for (uint32_t i = 0; i < phnum; i++)
		if (((ph[i].flags >> 24) & 7) == 2)
			hash = (int)i;
	if (hash < 0) {
		fprintf(stderr, "boot: no hash segment\n");
		return -1;
	}
	size_t ehsz = phoff + 32ull * phnum, meta_len = ehsz + ph[hash].filesz;
	uint8_t *meta = malloc(meta_len);
	memcpy(meta, mdt, ehsz);
	if (ph[hash].offset + ph[hash].filesz <= mlen) {
		memcpy(meta + ehsz, mdt + ph[hash].offset, ph[hash].filesz);
	} else {
		char path[128];
		size_t hl;
		snprintf(path, sizeof(path), FW_DIR "/modem.b%02d", hash);
		uint8_t *h = slurp(path, &hl);
		if (!h || hl < ph[hash].filesz) {
			fprintf(stderr, "boot: hash segment %s missing\n", path);
			return -1;
		}
		memcpy(meta + ehsz, h, ph[hash].filesz);
		free(h);
	}
	uint64_t meta_pa = pm_alloc(meta_len, 0x1000);
	if (!meta_pa)
		return -1;
	pm_wr(meta_pa, meta, meta_len);
	uint64_t r1 = 0;
	int64_t rc = scm(1, 2 | (2u << 6), PAS_MODEM, meta_pa, 0, &r1);
	printf("boot: init image (%zu bytes metadata at %llx) -> %lld/%llx\n", meta_len, (unsigned long long)meta_pa,
	       (long long)rc, (unsigned long long)r1);
	if (rc || r1)
		return -1;

	/* 3. memory setup for the relocatable image, then the segments at their addresses */
	rc = scm(2, 3, PAS_MODEM, MPSS_PA, MPSS_SIZE, &r1);
	printf("boot: mem setup %llx+%llx -> %lld/%llx\n", MPSS_PA, MPSS_SIZE, (long long)rc, (unsigned long long)r1);
	if (rc || r1)
		return -1;
	uint64_t total = 0;
	static uint8_t zeros[0x10000];
	for (uint32_t i = 0; i < phnum; i++) {
		if (ph[i].type != 1 || (int)i == hash || !ph[i].memsz)
			continue;
		uint64_t pa = ph[i].paddr;
		if (pa < MPSS_PA || pa + ph[i].memsz > MPSS_PA + MPSS_SIZE) {
			fprintf(stderr, "boot: segment %u at %llx outside the region\n", i, (unsigned long long)pa);
			return -1;
		}
		if (ph[i].filesz) {
			char path[128];
			size_t sl;
			snprintf(path, sizeof(path), FW_DIR "/modem.b%02u", i);
			uint8_t *seg = slurp(path, &sl);
			if (!seg || sl < ph[i].filesz) {
				fprintf(stderr, "boot: %s missing or short\n", path);
				return -1;
			}
			pm_wr(pa, seg, (ph[i].filesz + 3) & ~3u);
			free(seg);
			total += ph[i].filesz;
		}
		for (uint64_t o = (ph[i].filesz + 3) & ~3ull; o < ph[i].memsz; o += sizeof(zeros)) {
			uint64_t n = ph[i].memsz - o < sizeof(zeros) ? ph[i].memsz - o : sizeof(zeros);
			pm_wr(pa + o, zeros, (n + 3) & ~3ull);
		}
	}
	printf("boot: %llu bytes of segments loaded\n", (unsigned long long)total);

	/* 4. tell the AOP (Linux q6v5_prepare: before the Q6 runs), then authenticate and release reset */
	qmp_send("{class: image, res: load_state, name: modem, val: on}");
	/* a restart keeps the last run's state bits until the modem rewrites them: forget them */
	uint64_t ve;
	if (smp2p_in_entry("slave-kernel", &ve) == 0)
		wr32(ve, 0);
	modem_state = 0xffffffff;
	rc = scm(5, 1, PAS_MODEM, 0, 0, &r1);
	printf("boot: auth and reset -> %lld/%llx\n", (long long)rc, (unsigned long long)r1);
	if (rc || r1)
		return -1;

	/* 5. wait for SMP2P in: "ready" (bit 1) from the modem */
	for (int t = 0; t < 300; t++) {
		uint32_t v;
		smp2p_service();
		/* after a crash the old entry still says ready + fatal until the modem rewrites it */
		if (smp2p_in_value("slave-kernel", &v) == 0 && (v & 2) && !(v & 1)) {
			printf("boot: modem ready after %d00 ms\n", t);
			return 0;
		}
		usleep(100000);
	}
	printf("boot: no ready from the modem in 30 s\n");
	smp2p_show("in", 435);
	return -1;
}

static void net_cb(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n)
{
	uint32_t w[5] = { 0 };
	memcpy(w, d, n < sizeof(w) ? n : sizeof(w));
	if (h->type == QRTR_TYPE_DATA) {
		if (h->confirm_rx)
			qrtr_resume_tx(h);
		if (h->dst_port == RMTFS_PORT) {
			rmtfs_handle(h, d, n);
			return;
		}
		if (h->dst_port == WLFW_PORT) {
			wlfw_handle(h, d, n);
			return;
		}
		if (h->dst_port == PDMAPPER_PORT) {
			pdmapper_handle(h, d, n);
			return;
		}
		if (h->dst_port == TFTP_PORT || (h->dst_port >= TFTP_XFER_PORT0 && h->dst_port < TFTP_XFER_PORT0 + TFTP_XFERS)) {
			tftp_handle(h, d, n);
			return;
		}
		printf("qrtr: < DATA %u:%x -> %u:%x, %u bytes\n", h->src_node, h->src_port, h->dst_node, h->dst_port, n);
		return;
	}
	printf("[%6llu] qrtr: < ctrl type %u (cmd %u) from %u:%x: %x %x %x %x\n", (unsigned long long)link_ms(), h->type, w[0], h->src_node, h->src_port,
	       w[1], w[2], w[3], w[4]);
	if (w[0] == QRTR_TYPE_HELLO) {
		uint32_t hello[5] = { QRTR_TYPE_HELLO };	/* struct qrtr_ctrl_pkt: always 20 bytes */
		qrtr_send(QRTR_TYPE_HELLO, QRTR_PORT_CTRL, h->src_node, QRTR_PORT_CTRL, hello, sizeof(hello));
	} else if (w[0] == QRTR_TYPE_NEW_SERVER) {
		printf("qrtr:   server service %#x instance %#x at %u:%x\n", w[1], w[2], w[3], w[4]);
		if (w[1] == WLFW_SERVICE)
			wlfw_new_server(w[3], w[4]);
	}
}

/* the network to join: "ssid=NAME" and "psk=PASSPHRASE" lines (on the phone only, never in a repo) */
#define WLAN_CONF	"/var/local/wlan.conf"
static char conf_ssid[33], conf_psk[65];

static void read_conf(void)
{
	char line[128];
	FILE *f = fopen(WLAN_CONF, "r");
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\r\n")] = 0;
		if (!strncmp(line, "ssid=", 5))
			snprintf(conf_ssid, sizeof(conf_ssid), "%s", line + 5);
		else if (!strncmp(line, "psk=", 4))
			snprintf(conf_psk, sizeof(conf_psk), "%s", line + 4);
	}
	fclose(f);
	printf("net: will join '%s' (%s)\n", conf_ssid, conf_psk[0] ? "WPA2-PSK" : "open");
}

/*
 * Join after the first scan and stay joined: a failed try again after 5 s (4 times), then every 30 s with a
 * fresh scan first; a lost link (deauth, kickout, beacon miss) joins again after 3 s.
 */
static void join_poll(void)
{
	static int asked, joined, fails;
	static uint64_t next;
	if (!conf_ssid[0] || !radio_scans() || bridge_joins)
		return;				/* (wifid has taken over: bridge.c) */
	uint64_t now = link_ms();
	int r = radio_join_result();
	if (asked) {
		if (r == -1)
			return;				/* running */
		asked = 0;
		if (r == 0) {
			joined = 1;
			fails = 0;
			return;
		}
		fails++;
		next = now + (fails < 4 ? 5000 : 30000);
		if (fails >= 4)
			radio_rescan(25000);
		printf("[%6llu] net: join failed (%s), try %d, next in %llu s\n", (unsigned long long)now, strerror(r), fails,
		       (unsigned long long)(next - now) / 1000);
		return;
	}
	if (joined) {
		if (r != ENOTCONN)
			return;
		joined = 0;
		fails = 0;
		next = now + 3000;
		printf("[%6llu] net: link lost, joining again in 3 s\n", (unsigned long long)now);
		return;
	}
	if (next && now < next)
		return;
	r = radio_join(conf_ssid, conf_psk);
	printf("[%6llu] net: join '%s' (try %d) -> %d\n", (unsigned long long)now, conf_ssid, fails + 1, r);
	if (r == EINVAL || r == EIO) {
		printf("net: cannot join with this wlan.conf; not trying again\n");
		conf_ssid[0] = 0;
		return;
	}
	asked = 1;
}

static volatile sig_atomic_t drop_asked;

static void on_usr1(int sig)
{
	drop_asked = 1;
}

static void net_idle(void)
{
	if (drop_asked) {
		drop_asked = 0;
		radio_disconnect();
	}
	smp2p_service();
	radio_poll();
	ipnet_poll();
	bridge_poll();
	join_poll();
}

static int net(unsigned secs)
{
	if (getenv("WLAND_VERBOSE"))
		verbose_link = atoi(getenv("WLAND_VERBOSE"));
	link_idle = net_idle;
	signal(SIGUSR1, on_usr1);
	signal(SIGCHLD, SIG_IGN);	/* netsvc children (ipnet.c) reap themselves */
	if (link_up(net_cb, 5000))
		return -1;
	if (rmtfs_init())
		printf("net: no rmtfs\n");
	if (pdmapper_init() || tftp_init())
		printf("net: no pd-mapper/tftp\n");
	read_conf();
	uint64_t end = link_ms() + (uint64_t)secs * 1000, stats = link_ms() + 30000;
	while (!secs || link_ms() < end) {
		link_poll(100);
		if (link_ms() > stats) {
			radio_stats();
			stats = link_ms() + 30000;
		}
		if (!wlfw_pending())
			continue;
		if (wlfw_start()) {
			printf("net: WLFW bring-up failed\n");
		} else if (!getenv("WLAND_NO_RADIO")) {
			delay_ms(100);	/* topaz: only after mission mode; before it a CE access hangs the bus */
			if (radio_start())
				printf("net: radio start failed\n");
			else if (bridge_open() != 0 && conf_ssid[0] && ipnet_init())
				printf("net: no utun: joining without IP\n");
		}
	}
	radio_summary();
	radio_stats();
	return 0;
}

/* everything `up` does, from a fresh boot */
static int up(unsigned secs)
{
	if (smmu_wlan_identity())
		printf("up: no WLAN SMMU stream: the radio will not start\n");
	if (wlan_power() || smp2p_create() || boot_modem())
		return 1;
	return net(secs) ? 1 : 0;
}

/*
 * The boot job: `up 0` at most once per phone boot (a second modem boot in the same phone boot is untested and
 * MSA/rmtfs hangs wedge a CPU), unless switched off. stdout/stderr go to /var/local/wland.log.
 */
#define WLAND_LOG	"/var/local/wland.log"
#define WLAND_STAMP	"/var/local/wland.boot"
/* libsystem_kernel: jetsam control (root may change its own limits); MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES */
int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size);
struct memlimit_properties { int32_t active; uint32_t active_attr; int32_t inactive; uint32_t inactive_attr; };

/*
 * redfin 2026-10-28: every line of wland.log starts with the uptime ("[  73.342] ", seconds, as the kernel log), so the
 * bring-up's steps can be timed against launchd/wifid in the live log. stdout/stderr go through a pipe to a thread
 * that stamps each line; the pipe's write end is non-blocking, so a stuck logger can only lose lines, never stall
 * wland. WLAND_NOSTAMP=1 (or /var/local/wland.nostamp) writes the log as before.
 */
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <time.h>
#ifndef CLOCK_UPTIME_RAW
#define CLOCK_UPTIME_RAW CLOCK_MONOTONIC	/* (Darwin: mach_absolute_time, the kernel log's clock) */
#endif

static int stamp_out = -1;

static void *stamp_thread(void *arg)
{
	FILE *in = fdopen((int)(intptr_t)arg, "r");
	char line[1024];
	int at_start = 1;
	if (!in)
		return NULL;
	while (fgets(line, sizeof(line), in)) {
		char out[1100];
		int n = 0;
		if (at_start) {
			struct timespec ts;
			clock_gettime(CLOCK_UPTIME_RAW, &ts);
			n = snprintf(out, sizeof(out), "[%4ld.%03ld] ", (long)ts.tv_sec, ts.tv_nsec / 1000000);
		}
		size_t l = strlen(line);
		at_start = l && line[l - 1] == '\n';
		memcpy(out + n, line, l);
		if (write(stamp_out, out, (size_t)n + l) < 0)
			break;
	}
	return NULL;
}

static void stamp_log(void)
{
	int fds[2];
	pthread_t t;
	if (getenv("WLAND_NOSTAMP") || !access("/var/local/wland.nostamp", F_OK))
		return;
	if ((stamp_out = dup(1)) < 0 || pipe(fds))
		return;
	fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK);
	if (pthread_create(&t, NULL, stamp_thread, (void *)(intptr_t)fds[0])) {
		close(fds[0]);
		close(fds[1]);
		return;
	}
	pthread_detach(t);
	dup2(fds[1], 1);
	dup2(fds[1], 2);
	close(fds[1]);
}

static int auto_up(void)
{
	/* launchd's per-process limit for a job killed us while the modem firmware loaded (jetsam reason 7) */
	struct memlimit_properties ml = { 2048, 0, 2048, 0 };
	int mrc = memorystatus_control(7, getpid(), 0, &ml, sizeof(ml));
	char args[1024] = "";
	size_t n = sizeof(args) - 1;
	sysctlbyname("kern.bootargs", args, &n, NULL, 0);
	if (!access("/var/local/wland.off", F_OK) || strstr(args, "sweetwifi=0")) {
		fprintf(stderr, "wland: off (/var/local/wland.off or sweetwifi=0)\n");
		return 0;
	}
	struct timeval bt = { 0 };
	n = sizeof(bt);
	sysctlbyname("kern.boottime", &bt, &n, NULL, 0);
	char stamp[32] = "", now[32];
	snprintf(now, sizeof(now), "%ld\n", (long)bt.tv_sec);
	FILE *f = fopen(WLAND_STAMP, "r");
	if (f) {
		if (!fgets(stamp, sizeof(stamp), f))
			stamp[0] = 0;
		fclose(f);
	}
	if (!strcmp(stamp, now)) {
		fprintf(stderr, "wland: already started in this boot\n");
		return 1;
	}
	if ((f = fopen(WLAND_STAMP, "w"))) {
		fputs(now, f);
		fclose(f);
	}
	rename(WLAND_LOG, WLAND_LOG ".prev");
	if (freopen(WLAND_LOG, "a", stdout))
		dup2(fileno(stdout), 2);
	setvbuf(stdout, NULL, _IONBF, 0);
	stamp_log();
	printf("wland auto: boot %ld, memory limit 2048 MB -> %d\n", (long)bt.tv_sec, mrc);
	return up(0);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: wland smem | smp2p | vote RES LVL | levels RES | boot | sysctl NAME [VALUE]\n");
		return 2;
	}
	setvbuf(stdout, NULL, _IONBF, 0);	/* a stalled bus access must not swallow the output */
	if (!strcmp(argv[1], "sysctl") && argc > 2) {
		/* wland sysctl NAME [VALUE]: an int sysctl (kern.sweet_wifi_lqm, kern.sweet_wifi_rssi); iOS has no sysctl(8) */
		int v = 0, nv;
		size_t n = sizeof(v);
		if (argc > 3) {
			nv = (int)strtol(argv[3], NULL, 0);
			if (sysctlbyname(argv[2], NULL, NULL, &nv, sizeof(nv))) {
				perror(argv[2]);
				return 1;
			}
		}
		if (sysctlbyname(argv[2], &v, &n, NULL, 0)) {
			perror(argv[2]);
			return 1;
		}
		printf("%s = %d (%#x)\n", argv[2], v, v);
		return 0;
	}
	pm_init();
	if (smem_init())
		return 1;
	const char *c = argv[1];
	if (!strcmp(c, "smem")) {
		smem_dump();
	} else if (!strcmp(c, "smp2p")) {
		smp2p_show("in", 435);	/* qcom,smem = <435>, <428>: inbound, outbound */
		smp2p_show("out", 428);
	} else if (!strcmp(c, "levels") && argc > 2) {
		levels(argv[2], 1);
	} else if (!strcmp(c, "qmp") && argc > 2) {
		return qmp_send(argv[2]) ? 1 : 0;
	} else if (!strcmp(c, "smp2p-init")) {
		return smp2p_init() ? 1 : 0;
	} else if (!strcmp(c, "shutdown")) {
		uint64_t r1 = 0;
		int64_t rc = scm(6, 1, PAS_MODEM, 0, 0, &r1);	/* PAS_SHUTDOWN */
		printf("shutdown -> %lld/%llx\n", (long long)rc, (unsigned long long)r1);
		return rc ? 1 : 0;
	} else if (!strcmp(c, "items")) {
		smem_list();
	} else if (!strcmp(c, "item") && argc > 2) {
		uint64_t pa;
		uint32_t sz;
		unsigned host = argc > 3 ? (unsigned)strtoul(argv[3], NULL, 0) : SMEM_HOST_MODEM;
		if (smem_get(host, (unsigned)atoi(argv[2]), &pa, &sz)) {
			printf("item %s: not found\n", argv[2]);
			return 1;
		}
		printf("item %s: pa %llx size %u\n", argv[2], (unsigned long long)pa, sz);
		for (uint32_t o = 0; o < sz && o < 4096; o += 16) {
			uint8_t b[16];
			for (int k = 0; k < 16; k += 4) {
				uint32_t w = rd32(pa + o + k);
				memcpy(b + k, &w, 4);
			}
			printf("%04x:", o);
			for (int k = 0; k < 16; k++)
				printf(" %02x", b[k]);
			printf("  ");
			for (int k = 0; k < 16; k++)
				putchar(b[k] >= 32 && b[k] < 127 ? b[k] : '.');
			printf("\n");
		}
	} else if (!strcmp(c, "net")) {
		return net(argc > 2 ? (unsigned)atoi(argv[2]) : 10) ? 1 : 0;
	} else if (!strcmp(c, "auto")) {
		return auto_up();
	} else if (!strcmp(c, "up")) {
		/* everything from a fresh phone boot: SMP2P, the modem, GLINK + QRTR; the WLAN SMMU stream first */
		return up(argc > 2 ? (unsigned)atoi(argv[2]) : 20);
	} else if (!strcmp(c, "smmu")) {
		return smmu_wlan_identity() ? 1 : 0;
	} else if (!strcmp(c, "cmddb")) {
		cmddb_list();
	} else if (!strcmp(c, "wlan-power")) {
		return wlan_power() ? 1 : 0;
	} else if (!strcmp(c, "boot")) {
		return boot_modem() ? 1 : 0;
	} else if (!strcmp(c, "bcm") && argc > 3) {
		/* a BCM (bus) vote: x = average, y = peak, in the BCM's own units (0x3fff = its top level); commit + valid */
		uint32_t x = (uint32_t)strtoul(argv[2 + 1], NULL, 0) & 0x3fff, y = argc > 4 ? (uint32_t)strtoul(argv[4], NULL, 0) & 0x3fff : x;
		uint32_t off[1] = { 0 }, val[1] = { 1u << 30 | 1u << 29 | x << 14 | y };
		int rc = pm_rpmh(argv[2], 1, off, val);
		printf("bcm %s x %#x y %#x (%#x) -> %d\n", argv[2], x, y, val[0], rc);
		return rc ? 1 : 0;
	} else if (!strcmp(c, "vote") && argc > 3) {
		return vote(argv[2], (uint32_t)strtoul(argv[3], NULL, 0)) ? 1 : 0;
	} else {
		fprintf(stderr, "wland: unknown command\n");
		return 2;
	}
	return 0;
}
