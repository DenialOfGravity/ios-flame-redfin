#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "qca.h"
#include "tlv.h"

#define EDL_OP			0xFC00
#define EDL_VER_REQ		0x19
#define EDL_APP_VER_RES		0x02
#define EDL_TLV_REQ		0x1E
#define EDL_TLV_RES		0x04

static uint16_t le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | p[1] << 8);
}

static uint32_t le32(const uint8_t *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static int pulse(struct hci *h, unsigned baud, uint8_t byte, unsigned settle_ms)
{
	struct uart *u = h->u;
	if (u->set_baud(u, baud))
		return -1;
	u->set_flow(u, 0);
	hci_log(h, "BTD > power pulse 0x%02x at %u Bd (flow control off)\n", byte, baud);
	if (u->write(u, &byte, 1) < 0)
		return -1;
	if (u->drain(u, 100))
		hci_log(h, "BTD: pulse not drained in 100 ms\n");
	u->set_flow(u, 1);
	usleep(settle_ms * 1000);
	return 0;
}

int qca_power_pulses(struct hci *h)
{
	int sw0 = bt_sw_ctrl();
	/* qca_regulator_init: power-off pulse at 2400 Bd puts the chip in boot mode, then power-on at 115200 */
	if (pulse(h, 2400, 0xC0, 10) || pulse(h, 115200, 0xFC, 100))
		return -1;
	h->u->flush_rx(h->u);
	h->rpos = h->rlen = 0;
	hci_log(h, "BTD: SW_CTRL (TLMM 73) %d before the pulses, %d after\n", sw0, bt_sw_ctrl());
	return 0;
}

int qca_read_version(struct hci *h, struct qca_ver *v, unsigned ms)
{
	uint8_t cmd = EDL_VER_REQ;
	struct hci_pkt p;
	memset(v, 0, sizeof(*v));
	if (hci_send_cmd(h, EDL_OP, &cmd, 1))
		return -2;
	uint64_t end = now_ms() + ms;
	while (now_ms() < end) {
		if (hci_recv(h, &p, (unsigned)(end - now_ms())) <= 0 || p.type != H4_EVT)
			continue;
		const uint8_t *pl = p.data + 2, *ver = NULL;
		size_t plen = p.len - 2u;
		if (p.data[0] == EV_VENDOR && plen >= 14 && pl[0] == 0x00 &&
		    (pl[1] == EDL_APP_VER_RES || pl[1] == EDL_VER_REQ)) {
			ver = pl + 2;		/* WCN3990/3998: vendor event { cresp 0, rtype 2, version } */
		} else if (p.data[0] == EV_CMD_COMPLETE && plen >= 4 && le16(pl + 1) == EDL_OP) {
			const uint8_t *rp = pl + 3;	/* status (= cresp), rtype, one byte, version */
			size_t rn = plen - 3;
			if (rp[0] != 0) {
				hci_log(h, "BTD: EDL version request failed, status 0x%02x\n", rp[0]);
				return rp[0];
			}
			if (rn >= 15 && rp[1] == EDL_VER_REQ) {
				ver = rp + 3;
				v->cc_style = 1;
			} else {
				continue;	/* plain Command Complete; the vendor event follows */
			}
		} else {
			continue;
		}
		v->product_id = le32(ver);
		v->patch_ver = le16(ver + 4);
		v->rom_ver = le16(ver + 6);
		v->soc_id = le32(ver + 8);
		hci_log(h, "BTD: QCA product 0x%08x soc 0x%08x rom 0x%04x patch 0x%04x (%s) -> firmware crbtfw%02x, NVM crnv%02x%s\n",
			v->product_id, v->soc_id, v->rom_ver, v->patch_ver,
			v->cc_style ? "Command Complete: WCN3991-style" : "vendor event: WCN3990/3998-style",
			qca_rom_ver(v->soc_id, v->rom_ver), qca_rom_ver(v->soc_id, v->rom_ver),
			v->soc_id == QCA_WCN3991_SOC_ID ? "u" : "");
		return v->soc_id && v->rom_ver ? 0 : -3;
	}
	return -1;
}

static const unsigned bauds[] = {
	115200, 57600, 38400, 19200, 9600, 230400, 250000, 460800, 500000, 720000, 921600,
	1000000, 1250000, 2000000, 3000000, 4000000, 1600000, 3200000, 3500000,
};

int qca_baud_index(unsigned baud)
{
	for (unsigned i = 0; i < sizeof(bauds) / sizeof(bauds[0]); i++)
		if (bauds[i] == baud)
			return (int)i;
	return -1;
}

int qca_set_speed(struct hci *h, unsigned baud)
{
	int idx = qca_baud_index(baud);
	if (idx < 0 || idx > 17)
		return -1;
	struct uart *u = h->u;
	uint8_t cmd[4] = { 0x48, 0xFC, 0x01, (uint8_t)idx };
	u->set_flow(u, 0);	/* RTS held: the controller answers only after both sides switched */
	if (hci_send(h, H4_CMD, cmd, sizeof(cmd), 0)) {
		u->set_flow(u, 1);
		return -1;
	}
	u->drain(u, 100);
	usleep(10000);
	int r = u->set_baud(u, baud);
	u->set_flow(u, 1);
	hci_log(h, "BTD: host UART now %u Bd (%d); controller told index %d\n", baud, r, idx);
	/* WCN3990 sends a vendor event (Linux drops it); log whatever comes */
	hci_drain(h, 50);
	return r;
}

static uint8_t *slurp(const char *path, size_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = sz > 0 && sz < (8 << 20) ? malloc((size_t)sz) : NULL;
	if (b && fread(b, 1, (size_t)sz, f) != (size_t)sz) {
		free(b);
		b = NULL;
	}
	fclose(f);
	*n = b ? (size_t)sz : 0;
	return b;
}

/* the TLV result for one segment: vendor event { 00, 04, result } or (WCN3991) Command Complete { 00, 1E } */
static int seg_ack(struct hci *h, const struct qca_ver *v, unsigned ms)
{
	static const uint8_t m[2] = { 0x00, EDL_TLV_RES };
	struct hci_pkt p;
	uint64_t end = now_ms() + ms;
	while (now_ms() < end) {
		if (hci_recv(h, &p, (unsigned)(end - now_ms())) <= 0 || p.type != H4_EVT)
			continue;
		const uint8_t *pl = p.data + 2;
		size_t plen = p.len - 2u;
		if (!v->cc_style && p.data[0] == EV_VENDOR && plen >= 3 && !memcmp(pl, m, 2))
			return pl[2];
		if (p.data[0] == EV_CMD_COMPLETE && plen >= 4 && le16(pl + 1) == EDL_OP) {
			if (pl[3] != 0)
				return pl[3];
			if (v->cc_style && plen >= 5 && pl[4] == EDL_TLV_REQ)
				return 0;
			continue;	/* a segment's plain Command Complete (download modes 0/1) */
		}
		if (p.data[0] == EV_CMD_STATUS && plen >= 4 && le16(pl + 2) == EDL_OP && pl[0])
			return pl[0];
		if (h->on_async)
			h->on_async(h, &p);
	}
	return -1;
}

int qca_download(struct hci *h, const char *path, const struct qca_ver *v, int baud_idx, int ibs, unsigned *segs)
{
	size_t n;
	struct tlv_info ti;
	const char *err;
	*segs = 0;
	uint8_t *buf = slurp(path, &n);
	if (!buf) {
		hci_log(h, "BTD: %s: %s\n", path, strerror(errno ? errno : EIO));
		return -1;
	}
	if (tlv_parse(buf, n, &ti, &err)) {
		hci_log(h, "BTD: %s: %s\n", path, err);
		free(buf);
		return -1;
	}
	int mode = TLV_SKIP_NONE;
	if (ti.type == TLV_TYPE_PATCH) {
		mode = ti.dnld_mode;
		hci_log(h, "BTD: %s: rampatch %zu bytes, total %u data %u, format %u signature %u download mode %u, "
			"product 0x%04x rom build 0x%04x patch 0x%04x entry 0x%08x\n", path, n, ti.total_size,
			ti.data_length, ti.format_version, ti.signature, ti.dnld_mode, ti.product_id, ti.rom_build,
			ti.patch_version, ti.entry);
		if (ti.rom_build && v->rom_ver && ti.rom_build != v->rom_ver)
			hci_log(h, "BTD: warning: patch rom build 0x%04x but the controller says rom 0x%04x\n",
				ti.rom_build, v->rom_ver);
	} else {
		int c = tlv_nvm_edit(buf, n, baud_idx, v->cc_style ? 1 : 2, ibs, NULL);
		hci_log(h, "BTD: %s: NVM %zu bytes, %d tags, HCI tag %s, baud index %d, in-band sleep %s: %d bytes edited\n",
			path, n, ti.ntags, ti.hci_tag_len >= 0 ? "present" : "absent", baud_idx, ibs ? "on" : "off", c);
	}
	struct tlv_seg *sg = malloc(sizeof(*sg) * (n / TLV_SEG_MAX + 2));
	size_t ns = tlv_segments(n, mode, sg, n / TLV_SEG_MAX + 2);
	uint64_t t0 = now_ms();
	int rc = 0;
	for (size_t i = 0; i < ns; i++) {
		uint8_t cmd[3 + 2 + TLV_SEG_MAX];
		cmd[0] = (uint8_t)EDL_OP;
		cmd[1] = EDL_OP >> 8;
		cmd[2] = (uint8_t)(sg[i].len + 2);
		cmd[3] = EDL_TLV_REQ;
		cmd[4] = (uint8_t)sg[i].len;
		memcpy(cmd + 5, buf + sg[i].off, sg[i].len);
		if (h->verbose >= 1)
			hci_log(h, "BTD > CMD 0xfc00 QCA_EDL TLV segment %zu/%zu off %u len %u%s: %02x %02x %02x %02x ..\n",
				i + 1, ns, sg[i].off, sg[i].len, sg[i].want_ack ? " (acked)" : "",
				cmd[5], cmd[6], cmd[7], cmd[8]);
		if (hci_send(h, H4_CMD, cmd, 5u + sg[i].len, 1)) {
			hci_log(h, "BTD: segment %zu: UART write failed (CTS never ready?)\n", i + 1);
			rc = -1;
			break;
		}
		(*segs)++;
		if (sg[i].want_ack) {
			int r = seg_ack(h, v, 3000);
			if (r) {
				hci_log(h, "BTD: segment %zu/%zu: %s 0x%02x\n", i + 1, ns,
					r < 0 ? "no TLV result in 3 s" : "TLV result", r < 0 ? 0 : r);
				rc = -1;
				break;
			}
		} else {
			struct hci_pkt p;	/* keep the RX FIFO empty: mode 1 sends a Command Complete each */
			while (hci_recv(h, &p, 0) > 0)
				if (h->on_async)
					h->on_async(h, &p);
		}
	}
	if (!rc)
		hci_log(h, "BTD: %s: %zu segments in %llu ms\n", path, ns, (unsigned long long)(now_ms() - t0));
	free(sg);
	free(buf);
	return rc;
}

int qca_local_version(struct hci *h)
{
	uint8_t r[16];
	size_t n = sizeof(r);
	int s = hci_cmd(h, 0x1001, NULL, 0, r, &n, 2000);
	if (s || n < 9) {
		hci_log(h, "BTD: Read_Local_Version failed (%d)\n", s);
		return -1;
	}
	unsigned manu = r[5] | r[6] << 8;
	hci_log(h, "BTD: HCI version %u rev 0x%04x, LMP version %u subversion 0x%04x, manufacturer %u%s\n",
		r[1], r[2] | r[3] << 8, r[4], r[7] | r[8] << 8, manu, manu == 29 ? " (Qualcomm)" : "");
	return (int)manu;
}

static int read_bdaddr(struct hci *h, uint8_t out[6])
{
	uint8_t r[16];
	size_t n = sizeof(r);
	int s = hci_cmd(h, 0x1009, NULL, 0, r, &n, 2000);
	if (s || n < 7)
		return -1;
	for (int i = 0; i < 6; i++)
		out[i] = r[6 - i];	/* little endian on the wire */
	hci_log(h, "BTD: BD_ADDR %02x:%02x:%02x:%02x:%02x:%02x\n", out[0], out[1], out[2], out[3], out[4], out[5]);
	return 0;
}

int qca_set_bdaddr(struct hci *h, const uint8_t addr[6])
{
	uint8_t le[6], got[6], cmd[9];
	for (int i = 0; i < 6; i++)
		le[i] = addr[5 - i];
	read_bdaddr(h, got);
	if (!memcmp(got, addr, 6))
		return 0;
	/* qca_set_bdaddr_rome (the redbull kernel's choice): NVM access, set tag 2 */
	cmd[0] = 0x01;
	cmd[1] = 0x02;
	cmd[2] = 6;
	memcpy(cmd + 3, le, 6);
	uint8_t rsp[32];
	size_t rl = sizeof(rsp);
	int r = hci_cmd_ev(h, 0xFC0B, cmd, sizeof(cmd), EV_VENDOR, NULL, 0, rsp, &rl, 1000);
	hci_log(h, "BTD: 0xFC0B NVM tag 2 -> %d\n", r);
	if (!read_bdaddr(h, got) && !memcmp(got, addr, 6))
		return 0;
	/* mainline's choice for WCN399x: EDL_WRITE_BD_ADDR */
	rl = sizeof(rsp);
	r = hci_cmd_ev(h, 0xFC14, le, 6, EV_VENDOR, NULL, 0, rsp, &rl, 1000);
	hci_log(h, "BTD: 0xFC14 write BD_ADDR -> %d\n", r);
	if (!read_bdaddr(h, got) && !memcmp(got, addr, 6))
		return 0;
	return -1;
}
