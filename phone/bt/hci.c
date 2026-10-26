#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "hci.h"

uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static uint16_t le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | p[1] << 8);
}

int h4_feed(struct h4 *p, uint8_t *c)
{
	switch (p->state) {
	case 0:
		switch (*c) {
		case H4_CMD: case H4_SCO: p->hdr = 3; break;
		case H4_ACL: case H4_ISO: p->hdr = 4; break;
		case H4_EVT: p->hdr = 2; break;
		case IBS_WAKE_IND: case IBS_SLEEP_IND: case IBS_WAKE_ACK:
			return 2;
		default:
			return 3;
		}
		p->type = *c;
		p->got = 0;
		p->need = p->hdr;
		p->state = 1;
		return 0;
	case 1:
		p->data[p->got++] = *c;
		if (p->got < p->hdr)
			return 0;
		switch (p->type) {
		case H4_CMD: case H4_SCO: p->need = p->hdr + p->data[2]; break;
		case H4_ACL: p->need = p->hdr + le16(p->data + 2); break;
		case H4_ISO: p->need = p->hdr + (le16(p->data + 2) & 0x3fff); break;
		case H4_EVT: p->need = p->hdr + p->data[1]; break;
		}
		if (p->need > H4_MAX) {		/* garbage header: resynchronise on the next byte */
			p->state = 0;
			*c = p->type;
			return 3;
		}
		if (p->got == p->need) {
			p->state = 0;
			return 1;
		}
		p->state = 2;
		return 0;
	default:
		p->data[p->got++] = *c;
		if (p->got == p->need) {
			p->state = 0;
			return 1;
		}
		return 0;
	}
}

void hci_init(struct hci *h, struct uart *u, int verbose)
{
	memset(h, 0, sizeof(*h));
	h->u = u;
	h->verbose = verbose;
	h->t0 = now_ms();
}

void hci_log(struct hci *h, const char *fmt, ...)
{
	va_list ap;
	uint64_t t = now_ms() - h->t0;
	printf("[%5llu.%03llu] ", (unsigned long long)(t / 1000), (unsigned long long)(t % 1000));
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fflush(stdout);
}

static const struct { uint16_t op; const char *name; } ops[] = {
	{ 0x0401, "Inquiry" }, { 0x0c01, "Set_Event_Mask" }, { 0x0c03, "Reset" },
	{ 0x0c14, "Read_Local_Name" }, { 0x1001, "Read_Local_Version" }, { 0x1002, "Read_Local_Commands" },
	{ 0x1003, "Read_Local_Features" }, { 0x1005, "Read_Buffer_Size" }, { 0x1009, "Read_BD_ADDR" },
	{ 0x2001, "LE_Set_Event_Mask" }, { 0x2002, "LE_Read_Buffer_Size" }, { 0x2003, "LE_Read_Local_Features" },
	{ 0x200b, "LE_Set_Scan_Parameters" }, { 0x200c, "LE_Set_Scan_Enable" },
	{ 0xfc00, "QCA_EDL" }, { 0xfc0b, "QCA_NVM_Access" }, { 0xfc14, "QCA_Write_BD_ADDR" },
	{ 0xfc48, "QCA_Set_Baudrate" }, { 0xfc17, "QCA_Logging" }, { 0xfc08, "QCA_Pre_Shutdown" },
};

const char *hci_op_name(uint16_t op)
{
	for (size_t i = 0; i < sizeof(ops) / sizeof(ops[0]); i++)
		if (ops[i].op == op)
			return ops[i].name;
	return "";
}

static void hexs(char *out, size_t cap, const uint8_t *d, size_t n, size_t max)
{
	size_t o = 0;
	out[0] = 0;
	for (size_t i = 0; i < n && i < max && o + 4 < cap; i++)
		o += (size_t)snprintf(out + o, cap - o, "%s%02x", i ? " " : "", d[i]);
	if (n > max && o + 4 < cap)
		snprintf(out + o, cap - o, " ..");
}

void hci_log_pkt(struct hci *h, int out, uint8_t type, const uint8_t *d, size_t n)
{
	char hx[3 * H4_MAX + 8], what[128];
	size_t max = h->verbose >= 2 ? n : 32;
	const char *dir = out ? ">" : "<";
	what[0] = 0;
	switch (type) {
	case H4_CMD: {
		uint16_t op = le16(d);
		snprintf(what, sizeof(what), "CMD 0x%04x %s plen %u", op, hci_op_name(op), d[2]);
		hexs(hx, sizeof(hx), d + 3, n - 3, max);
		break;
	}
	case H4_EVT:
		if (d[0] == EV_CMD_COMPLETE && n >= 6)
			snprintf(what, sizeof(what), "EVT 0x0e Command_Complete op 0x%04x %s status 0x%02x",
				le16(d + 3), hci_op_name(le16(d + 3)), d[5]);
		else if (d[0] == EV_CMD_STATUS && n >= 6)
			snprintf(what, sizeof(what), "EVT 0x0f Command_Status op 0x%04x %s status 0x%02x",
				le16(d + 4), hci_op_name(le16(d + 4)), d[2]);
		else if (d[0] == EV_LE_META && n >= 3)
			snprintf(what, sizeof(what), "EVT 0x3e LE_Meta sub 0x%02x plen %u", d[2], d[1]);
		else if (d[0] == EV_VENDOR)
			snprintf(what, sizeof(what), "EVT 0xff Vendor plen %u", d[1]);
		else if (d[0] == EV_HW_ERROR)
			snprintf(what, sizeof(what), "EVT 0x10 Hardware_Error code 0x%02x", n > 2 ? d[2] : 0);
		else
			snprintf(what, sizeof(what), "EVT 0x%02x plen %u", d[0], d[1]);
		hexs(hx, sizeof(hx), d + 2, n - 2, max);
		break;
	case H4_ACL:
		snprintf(what, sizeof(what), "ACL handle 0x%03x len %u", le16(d) & 0xfff, le16(d + 2));
		hexs(hx, sizeof(hx), d + 4, n - 4, max);
		break;
	default:
		snprintf(what, sizeof(what), "PKT type %u len %zu", type, n);
		hexs(hx, sizeof(hx), d, n, max);
	}
	hci_log(h, "BTD %s %s%s%s\n", dir, what, hx[0] ? ": " : "", hx);
}

int hci_send(struct hci *h, uint8_t type, const uint8_t *data, size_t n, int quiet)
{
	uint8_t pkt[1 + H4_MAX];
	if (n > H4_MAX)
		return -1;
	if (h->ibs && h->peer_asleep) {
		/* the controller said it sleeps: wake it, then expect IBS_WAKE_ACK (hci_recv clears peer_asleep) */
		uint8_t w = IBS_WAKE_IND;
		hci_log(h, "BTD > IBS wake indication\n");
		h->u->write(h->u, &w, 1);
		struct hci_pkt p;
		uint64_t end = now_ms() + 100;
		while (h->peer_asleep && now_ms() < end)
			if (hci_recv(h, &p, 10) > 0 && h->on_async)
				h->on_async(h, &p);
		if (h->peer_asleep)
			hci_log(h, "BTD: no IBS wake acknowledgement in 100 ms; sending anyway\n");
	}
	pkt[0] = type;
	memcpy(pkt + 1, data, n);
	if (h->verbose >= 1 && !quiet)
		hci_log_pkt(h, 1, type, data, n);
	h->n_tx++;
	return h->u->write(h->u, pkt, n + 1) < 0 ? -1 : 0;
}

int hci_send_cmd(struct hci *h, uint16_t op, const uint8_t *p, uint8_t n)
{
	uint8_t b[3 + 255];
	b[0] = (uint8_t)op;
	b[1] = (uint8_t)(op >> 8);
	b[2] = n;
	if (n)
		memcpy(b + 3, p, n);
	return hci_send(h, H4_CMD, b, 3u + n, 0);
}

static void ibs_byte(struct hci *h, uint8_t c)
{
	h->n_ibs++;
	if (h->tap)
		h->tap(h, c, NULL, 0);
	switch (c) {
	case IBS_WAKE_IND: {
		hci_log(h, "BTD < IBS wake indication%s\n", h->ibs ? ": acknowledged" : " (IBS off: acknowledged anyway)");
		uint8_t a = IBS_WAKE_ACK;
		h->u->write(h->u, &a, 1);
		h->peer_asleep = 0;
		break;
	}
	case IBS_SLEEP_IND:
		hci_log(h, "BTD < IBS sleep indication\n");
		h->peer_asleep = 1;
		break;
	case IBS_WAKE_ACK:
		hci_log(h, "BTD < IBS wake acknowledgement\n");
		h->peer_asleep = 0;
		break;
	}
}

int hci_recv(struct hci *h, struct hci_pkt *p, unsigned ms)
{
	uint64_t end = now_ms() + ms;
	for (;;) {
		while (h->rpos < h->rlen) {
			uint8_t c = h->rbuf[h->rpos++];
			int r = h4_feed(&h->rx, &c);
			if (r == 1) {
				p->type = h->rx.type;
				p->len = h->rx.got;
				p->data = h->rx.data;
				h->n_rx++;
				if (h->verbose >= 1)
					hci_log_pkt(h, 0, p->type, p->data, p->len);
				if (p->type == H4_EVT && p->data[0] == EV_HW_ERROR)
					h->n_hwerr++;
				if (h->tap)
					h->tap(h, p->type, p->data, p->len);
				return 1;
			}
			if (r == 2)
				ibs_byte(h, c);
			else if (r == 3) {
				if (h->n_junk++ < 64)
					hci_log(h, "BTD < junk byte 0x%02x outside a packet\n", c);
			}
		}
		/* always one read, also with ms = 0 (a poll), then give up once the time is over */
		uint64_t t = now_ms();
		unsigned left = ms == (unsigned)-1 ? 1000 : (unsigned)(end > t ? end - t : 0);
		int n = h->u->read(h->u, h->rbuf, sizeof(h->rbuf), left);
		if (n < 0)
			return -1;
		h->rpos = 0;
		h->rlen = (size_t)n;
		if (n == 0 && ms != (unsigned)-1 && now_ms() >= end)
			return 0;
	}
}

static int wait_for(struct hci *h, uint16_t op, uint8_t evt, const uint8_t *match, size_t mlen,
	uint8_t *rsp, size_t *rlen, unsigned ms)
{
	uint64_t end = now_ms() + ms;
	struct hci_pkt p;
	for (;;) {
		uint64_t t = now_ms();
		if (t >= end)
			return -1;
		int r = hci_recv(h, &p, (unsigned)(end - t));
		if (r < 0)
			return -1;
		if (r == 0)
			continue;
		if (p.type == H4_EVT) {
			const uint8_t *pl = p.data + 2;
			size_t plen = p.len - 2u;
			/* the answer to op */
			if (op && p.data[0] == EV_CMD_COMPLETE && plen >= 4 && le16(pl + 1) == op) {
				if (evt == EV_CMD_COMPLETE || pl[3] != 0) {
					if (rsp && rlen) {
						size_t n = plen - 3 < *rlen ? plen - 3 : *rlen;
						memcpy(rsp, pl + 3, n);
						*rlen = n;
					}
					return pl[3];
				}
				continue;	/* success; the event we want comes separately */
			}
			if (op && p.data[0] == EV_CMD_STATUS && plen >= 4 && le16(pl + 2) == op) {
				if (pl[0] != 0)
					return pl[0];
				if (evt == EV_CMD_STATUS)
					return 0;
				continue;
			}
			if (p.data[0] == evt && evt != EV_CMD_COMPLETE && plen >= mlen &&
			    (!mlen || !memcmp(pl, match, mlen))) {
				if (rsp && rlen) {
					size_t n = plen < *rlen ? plen : *rlen;
					memcpy(rsp, pl, n);
					*rlen = n;
				}
				return 0;
			}
		}
		if (h->on_async)
			h->on_async(h, &p);
	}
}

int hci_cmd(struct hci *h, uint16_t op, const uint8_t *p, uint8_t n, uint8_t *rsp, size_t *rlen, unsigned ms)
{
	if (hci_send_cmd(h, op, p, n))
		return -2;
	return wait_for(h, op, EV_CMD_COMPLETE, NULL, 0, rsp, rlen, ms);
}

int hci_cmd_ev(struct hci *h, uint16_t op, const uint8_t *p, uint8_t n, uint8_t evt, const uint8_t *match,
	size_t mlen, uint8_t *rsp, size_t *rlen, unsigned ms)
{
	if (op && hci_send_cmd(h, op, p, n))
		return -2;
	return wait_for(h, op, evt, match, mlen, rsp, rlen, ms);
}

int hci_wait_ev(struct hci *h, uint8_t evt, const uint8_t *match, size_t mlen, uint8_t *rsp, size_t *rlen,
	unsigned ms)
{
	return wait_for(h, 0, evt, match, mlen, rsp, rlen, ms);
}

void hci_drain(struct hci *h, unsigned ms)
{
	uint64_t end = now_ms() + ms;
	struct hci_pkt p;
	while (now_ms() < end)
		if (hci_recv(h, &p, (unsigned)(end - now_ms())) > 0 && h->on_async)
			h->on_async(h, &p);
}
