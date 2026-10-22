/*
 * WLFW (QMI service 0x45): the WLAN firmware's control service on the
 * modem, driven as Linux ath10k qmi.c does for WCN3990 (snoc): indications,
 * host caps, MSA memory (hyp_assign'd to the modem and the WLAN VMs), MSA
 * ready, capabilities, board data download, then on FW ready: wlan config
 * (the copy engine tables from ath10k snoc.c) and mission mode.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "link.h"
#include "qmi.h"
#include "scm.h"
#include "wlfw.h"

#define IND_REGISTER	0x20
#define FW_READY_IND	0x21
#define WLAN_MODE	0x22
#define WLAN_CFG	0x23
#define CAP		0x24
#define BDF_DOWNLOAD	0x25
#define CAL_REPORT	0x26
#define MSA_READY_IND	0x2b
#define PIN_RESULT_IND	0x2c
#define MSA_INFO	0x2d
#define MSA_READY	0x2e
#define MAC_ADDR	0x33
#define HOST_CAP	0x34
#define FW_INIT_DONE_IND 0x38

#define CLIENT_ID	0x4b4e454c	/* ath10k's */
#define MSA_PA		0x8bc00000ull	/* pil_wlan_fw_region */
#define MSA_SIZE	0x100000u	/* qcom,wlan-msa-memory */
#define BDF_PATH	"/var/local/fw/modem/bdwlan-flame.bin"
#define BDF_PATH2	"/var/local/fw/modem/bdwlan-flame-PROTO1.1.bin"

static uint32_t srv_node, srv_port;
static int srv_up, started;
static volatile int fw_ready, msa_ready;
struct wlfw_info wlfw;

static struct {
	uint16_t txn, id;
	int waiting, done;
	uint8_t buf[8192];
	uint32_t n;
} pend;

void wlfw_new_server(uint32_t node, uint32_t port)
{
	srv_node = node;
	srv_port = port;
	srv_up = 1;
	printf("wlfw: server at %u:%x\n", node, port);
}

int wlfw_pending(void)
{
	return srv_up && !started;
}

void wlfw_handle(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n)
{
	struct qmi_msg m;
	if (qmi_parse(d, n, &m))
		return;
	if (m.type == QMI_RESPONSE) {
		if (pend.waiting && m.txn == pend.txn && n <= sizeof(pend.buf)) {
			memcpy(pend.buf, d, n);
			pend.n = n;
			pend.done = 1;
		}
		return;
	}
	if (m.type != QMI_INDICATION)
		return;
	switch (m.id) {
	case FW_READY_IND:
		printf("wlfw: < FW READY\n");
		fw_ready = 1;
		break;
	case MSA_READY_IND:
		printf("wlfw: < MSA READY\n");
		msa_ready = 1;
		break;
	case FW_INIT_DONE_IND:
		printf("wlfw: < FW INIT DONE\n");
		break;
	default:
		printf("wlfw: < indication ");
		qmi_dump(&m);
		break;
	}
}

/* Send a request and wait for its response (into *r); returns the QMI error, -1 on timeout. */
static int request(struct qmi_buf *q, struct qmi_msg *r, unsigned ms)
{
	static uint16_t txn = 1;
	uint16_t id;
	memcpy(&id, q->b + 3, 2);
	pend.txn = txn;
	memcpy(q->b + 1, &txn, 2);
	txn++;
	pend.id = id;
	pend.done = 0;
	pend.waiting = 1;
	qrtr_send(QRTR_TYPE_DATA, WLFW_PORT, srv_node, srv_port, q->b, (uint32_t)qmi_finish(q));
	for (unsigned t = 0; !pend.done && t < ms; t++)
		link_poll(1);
	pend.waiting = 0;
	if (!pend.done) {
		printf("wlfw: request %#x timed out\n", id);
		return -1;
	}
	qmi_parse(pend.buf, pend.n, r);
	uint16_t l;
	const uint8_t *res = qmi_get(r, 2, &l);
	uint16_t result = 0, error = 0;
	if (res && l >= 4) {
		memcpy(&result, res, 2);
		memcpy(&error, res + 2, 2);
	}
	if (result) {
		printf("wlfw: request %#x -> result %u error %u: ", id, result, error);
		qmi_dump(r);
	}
	return result ? (error ? error : 1) : 0;
}

/* ath10k snoc.c target_ce_config_wlan: pipe, dir, nentries, nbytes_max, flags */
static const uint32_t tgt_ce[12][5] = {
	{ 0, 2, 32, 2048, 0 },  { 1, 1, 32, 2048, 0 },	{ 2, 1, 64, 2048, 0 },	{ 3, 2, 32, 2048, 0 },
	{ 4, 2, 256, 256, 8 },	{ 5, 2, 1024, 64, 8 },	{ 6, 3, 32, 16384, 0 }, { 7, 4, 0, 0, 8 },
	{ 8, 1, 32, 2048, 0 },	{ 9, 1, 32, 2048, 0 },	{ 10, 1, 32, 2048, 0 }, { 11, 1, 32, 2048, 0 },
};
/* target_service_to_ce_map_wlan: service, dir, pipe (the zero entry included, as ath10k sends it) */
static const uint32_t svc_map[21][3] = {
	{ 0x104, 2, 3 }, { 0x104, 1, 2 }, { 0x102, 2, 3 }, { 0x102, 1, 2 }, { 0x101, 2, 3 }, { 0x101, 1, 2 },
	{ 0x103, 2, 3 }, { 0x103, 1, 2 }, { 0x100, 2, 3 }, { 0x100, 1, 2 }, { 0x001, 2, 0 }, { 0x001, 1, 2 },
	{ 0xfe00, 2, 0 }, { 0xfe00, 1, 2 }, { 0x300, 2, 4 }, { 0x300, 1, 1 }, { 0xfe00, 2, 5 }, { 0x301, 1, 9 },
	{ 0x302, 1, 10 }, { 0x600, 1, 11 }, { 0, 0, 0 },
};
/* target_shadow_reg_cfg_map: ce, register offset (SRC_WR_IDX 0x3c, DST_WR_IDX 0x40); all 12 as Linux sends them */
static const uint16_t shadow[12][2] = {
	{ 0, 0x3c }, { 3, 0x3c }, { 4, 0x3c }, { 5, 0x3c }, { 7, 0x3c }, { 1, 0x40 },
	{ 2, 0x40 }, { 7, 0x40 }, { 8, 0x40 }, { 9, 0x40 }, { 10, 0x40 }, { 11, 0x40 },
};

/* variant: file_id (-1 = leave out), bdf_type (-1 = leave out) */
static int bdf_download(const char *path, int file_id, int bdf_type, unsigned seg_size)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		printf("wlfw: no %s\n", path);
		return -1;
	}
	static uint8_t bdf[256 * 1024];
	ssize_t len = read(fd, bdf, sizeof(bdf));
	close(fd);
	if (len <= 0)
		return -1;
	uint32_t seg = 0;
	for (ssize_t off = 0; off < len; seg++) {
		uint16_t chunk = (uint16_t)(len - off > seg_size ? seg_size : len - off);
		struct qmi_buf q;
		struct qmi_msg r;
		qmi_start(&q, QMI_REQUEST, 0, BDF_DOWNLOAD);
		qmi_tlv_u8(&q, 0x01, 1);		/* valid */
		if (file_id >= 0)
			qmi_tlv_u32(&q, 0x10, (uint32_t)file_id);	/* file_id */
		qmi_tlv_u32(&q, 0x11, (uint32_t)len);	/* total_size */
		qmi_tlv_u32(&q, 0x12, seg);		/* seg_id */
		uint8_t data[2 + 6144];
		memcpy(data, &chunk, 2);
		memcpy(data + 2, bdf + off, chunk);
		qmi_tlv(&q, 0x13, data, (uint16_t)(2 + chunk));
		int end = off + chunk >= len;
		qmi_tlv_u8(&q, 0x14, (uint8_t)end);
		if (bdf_type >= 0)		/* downstream field after "end": 0 BIN, 1 ELF, 2 REGDB */
			qmi_tlv_u8(&q, 0x15, (uint8_t)bdf_type);
		int e = request(&q, &r, 5000);
		if (e)
			printf("wlfw: BDF segment %u (%u bytes at %zd%s) -> error %d\n", seg, chunk, off, end ? ", end" : "", e);
		/* end = 1 makes the firmware check a CRC that released BDFs often fail (ath10k: not fatal) */
		if (e && !(end && e == 1))
			return -1;
		off += chunk;
	}
	printf("wlfw: board data sent (%s, %zd bytes, %u segments)\n", path, len, seg);
	return 0;
}

static int wlan_enable(void)
{
	struct qmi_buf q;
	struct qmi_msg r;
	qmi_start(&q, QMI_REQUEST, 0, WLAN_CFG);
	uint8_t b[1 + 24 * 21];
	b[0] = 12;
	for (int i = 0; i < 12; i++) {
		uint32_t e[5];
		memcpy(e, tgt_ce[i], sizeof(e));
		memcpy(b + 1 + 20 * i, e, 20);
	}
	qmi_tlv(&q, 0x11, b, 1 + 20 * 12);
	b[0] = 21;
	for (int i = 0; i < 21; i++)
		memcpy(b + 1 + 12 * i, svc_map[i], 12);
	qmi_tlv(&q, 0x12, b, 1 + 12 * 21);
	b[0] = 12;
	for (int i = 0; i < 12; i++)
		memcpy(b + 1 + 4 * i, shadow[i], 4);
	qmi_tlv(&q, 0x13, b, 1 + 4 * 12);
	if (request(&q, &r, 5000))
		return -1;
	qmi_start(&q, QMI_REQUEST, 0, WLAN_MODE);
	qmi_tlv_u32(&q, 0x01, 0);	/* QMI_WLFW_MISSION_V01 */
	qmi_tlv_u8(&q, 0x10, 0);	/* hw_debug */
	if (request(&q, &r, 5000))
		return -1;
	printf("wlfw: wlan config sent, mission mode on\n");
	return 0;
}

int wlfw_start(void)
{
	struct qmi_buf q;
	struct qmi_msg r;
	started = 1;

	qmi_start(&q, QMI_REQUEST, 0, IND_REGISTER);
	qmi_tlv_u8(&q, 0x10, 1);		/* fw_ready_enable */
	qmi_tlv_u8(&q, 0x13, 1);		/* msa_ready_enable */
	qmi_tlv_u8(&q, 0x14, 1);		/* pin_connect_result_enable (icnss) */
	qmi_tlv_u32(&q, 0x15, CLIENT_ID);
	if (request(&q, &r, 5000))
		return -1;
	uint16_t l;
	const uint8_t *p = qmi_get(&r, 0x10, &l);
	uint64_t fw_status = 0;
	if (p && l >= 8)
		memcpy(&fw_status, p, 8);
	printf("wlfw: registered for indications, fw status %#llx\n", (unsigned long long)fw_status);
	if (fw_status & 2)
		fw_ready = 1;

	if (!fw_ready) {
		if (!getenv("WLFW_NO_HOSTCAP")) {	/* downstream icnss never sends it */
			qmi_start(&q, QMI_REQUEST, 0, HOST_CAP);
			qmi_tlv_u32(&q, 0x10, 0);	/* daemon_support */
			int e = request(&q, &r, 5000);
			if (e && e != 0x5e)		/* QMI_ERR_NOT_SUPPORTED: older firmware */
				return -1;
		}

		qmi_start(&q, QMI_REQUEST, 0, MSA_INFO);
		qmi_tlv_u64(&q, 0x01, MSA_PA);
		qmi_tlv_u32(&q, 0x02, MSA_SIZE);
		if (request(&q, &r, 5000))
			return -1;
		p = qmi_get(&r, 0x03, &l);
		unsigned nreg = p && l ? p[0] : 0;
		for (unsigned i = 0; i < nreg && 1 + 13 * (i + 1) <= l; i++) {
			uint64_t a;
			uint32_t sz;
			memcpy(&a, p + 1 + 13 * i, 8);
			memcpy(&sz, p + 1 + 13 * i + 8, 4);
			uint8_t secure = p[1 + 13 * i + 12];
			printf("wlfw: MSA region %u: %llx+%x%s\n", i, (unsigned long long)a, sz, secure ? " secure" : "");
			if (a < MSA_PA || a + sz > MSA_PA + MSA_SIZE)
				return -1;
			usleep(20000);		/* ath10k: SDM845 crashes on an XPU update right after the reply */
			static const uint32_t src[] = { VMID_HLOS };
			const uint32_t dst[] = { VMID_MSS_MSA, VMID_WLAN, VMID_WLAN_CE };
			int nd = secure ? 2 : 3;
			/*
			 * A failure here means the region is still the modem's and WLAN's from a run before
			 * this modem restart: the owners are already the ones we want. (Taking it back
			 * while the WLAN firmware runs never returns from the secure world: never do that.)
			 */
			if (hyp_assign(a, sz, src, 1, dst, nd))
				printf("wlfw: MSA region %u already assigned\n", i);
		}
		qmi_start(&q, QMI_REQUEST, 0, MSA_READY);
		if (request(&q, &r, 5000))
			return -1;
	}

	qmi_start(&q, QMI_REQUEST, 0, CAP);
	if (request(&q, &r, 5000))
		return -1;
	if ((p = qmi_get(&r, 0x10, &l)) && l >= 8) {
		memcpy(&wlfw.chip_id, p, 4);
		memcpy(&wlfw.chip_family, p + 4, 4);
	}
	if ((p = qmi_get(&r, 0x11, &l)) && l >= 4)
		memcpy(&wlfw.board_id, p, 4);
	if ((p = qmi_get(&r, 0x12, &l)) && l >= 4)
		memcpy(&wlfw.soc_id, p, 4);
	if ((p = qmi_get(&r, 0x13, &l)) && l >= 4)
		memcpy(&wlfw.fw_version, p, 4);
	if ((p = qmi_get(&r, 0x14, &l)) && l)
		memcpy(wlfw.build_id, p, l < sizeof(wlfw.build_id) - 1 ? l : sizeof(wlfw.build_id) - 1);
	printf("wlfw: chip %#x family %#x board %#x soc %#x fw %#x \"%s\"\n", wlfw.chip_id, wlfw.chip_family,
	       wlfw.board_id, wlfw.soc_id, wlfw.fw_version, wlfw.build_id);

	if (!fw_ready) {
		/* ath10k waits for the MSA ready indication before the board data */
		for (int t = 0; t < 5000 && !msa_ready; t++)
			link_poll(1);
		/* which request shape this firmware takes is not known yet: try them in turn */
		static const struct { const char *path; int file_id, type; unsigned seg; } v[] = {
			{ BDF_PATH, 0, -1, 6144 },
		};
		int ok = 0;
		for (unsigned i = 0; i < sizeof(v) / sizeof(v[0]) && !ok; i++) {
			printf("wlfw: BDF try %u: file_id %d type %d seg %u %s\n", i, v[i].file_id, v[i].type, v[i].seg, v[i].path);
			ok = !bdf_download(v[i].path, v[i].file_id, v[i].type, v[i].seg);
		}
		if (!ok)
			return -1;
		/* cnss-daemon sends the MAC address (0x33) before the cal report: a locally administered one */
		qmi_start(&q, QMI_REQUEST, 0, MAC_ADDR);
		static const uint8_t mac[6] = { 0x02, 0x50, 0x49, 0x58, 0x45, 0x4c };
		qmi_tlv(&q, 0x10, mac, 6);
		printf("wlfw: mac address -> %d\n", request(&q, &r, 5000));
		if (!getenv("WLFW_NO_CALREPORT")) {
			qmi_start(&q, QMI_REQUEST, 0, CAL_REPORT);
			uint8_t none = 0;
			qmi_tlv(&q, 0x01, &none, 1);	/* meta_data[]: none */
			printf("wlfw: cal report -> %d\n", request(&q, &r, 5000));
		}
		for (int t = 0; t < 10000 && !fw_ready; t++)
			link_poll(1);
		if (!fw_ready) {
			printf("wlfw: no FW READY\n");
			return -1;
		}
	}
	return wlan_enable();
}
