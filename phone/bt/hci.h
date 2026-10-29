/*
 * H4 (UART) HCI transport over struct uart: framing, in-band sleep bytes, command/event helpers and a
 * one-line log of every packet in both directions ("BTD >" to the controller, "BTD <" from it).
 */
#ifndef BT_HCI_H
#define BT_HCI_H
#include <stddef.h>
#include <stdint.h>
#include "uart.h"

#define H4_CMD		0x01
#define H4_ACL		0x02
#define H4_SCO		0x03
#define H4_EVT		0x04
#define H4_ISO		0x05
#define H4_MAX		(4 + 1024 + 8)

/* QCA in-band sleep (Linux hci_qca.c HCI_IBS_*, hakios vayu_bt.c BT_H4_*), single bytes between packets.
   Up to 68cef4c these two were swapped: the WCN3998's 0xFD wake indications (it wants to send, waiting for
   our 0xFC) were taken for sleep indications and never acknowledged, so it retransmitted 0xFD every ~20 ms
   and no event after an idle period ever came through (r57a: the HCI Reset of bluetoothd). */
#define IBS_WAKE_IND	0xFD
#define IBS_SLEEP_IND	0xFE
#define IBS_WAKE_ACK	0xFC

#define EV_CMD_COMPLETE	0x0E
#define EV_CMD_STATUS	0x0F
#define EV_HW_ERROR	0x10
#define EV_LE_META	0x3E
#define EV_VENDOR	0xFF

struct h4 {
	int state;		/* 0 type, 1 header, 2 payload */
	uint8_t type;
	uint16_t hdr, need, got;
	uint8_t data[H4_MAX];	/* header + payload, without the type byte */
};
/* 0 need more, 1 packet in p (p->type, p->data, p->got), 2 an IBS byte (in *c), 3 junk byte (in *c) */
int h4_feed(struct h4 *p, uint8_t *c);

struct hci_pkt {
	uint8_t type;
	uint16_t len;
	const uint8_t *data;	/* header + payload; valid until the next receive */
};

struct hci {
	struct uart *u;
	int verbose;		/* 0 errors only, 1 every packet one line, 2 + full hex */
	int ibs;		/* wake the controller (0xFD, wait for 0xFC) before sending when it said it sleeps: --ibs,
			   and btd --bridge unless BTD_IBS=0. 0xFD from the controller is acknowledged either way. */
	int peer_asleep;
	uint8_t rbuf[512];
	size_t rpos, rlen;
	struct h4 rx;
	uint64_t t0;
	unsigned long n_tx, n_rx, n_junk, n_ibs, n_hwerr;
	uint8_t ibs_last;		/* the last IBS byte and how many came in a row (with no packet between) */
	unsigned long ibs_run;
	uint64_t ibs_first;
	unsigned long n_wake_ack, n_wake_tx;	/* 0xFC sent for the controller's 0xFD; 0xFD sent by hci_send */
	/* every received packet not consumed by the command being waited for (advertising reports...) */
	void (*on_async)(struct hci *h, const struct hci_pkt *p);
	/* raw bridge: every received packet and IBS byte, before any interpretation */
	void (*tap)(struct hci *h, uint8_t type, const uint8_t *data, size_t len);
	void *user;
};

void hci_init(struct hci *h, struct uart *u, int verbose);
void hci_log(struct hci *h, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void hci_log_pkt(struct hci *h, int out, uint8_t type, const uint8_t *d, size_t n);

/* one packet (type byte + data) to the controller; logs it unless quiet */
int hci_send(struct hci *h, uint8_t type, const uint8_t *data, size_t n, int quiet);
int hci_send_cmd(struct hci *h, uint16_t op, const uint8_t *p, uint8_t n);
/* next packet within ms (0 = none). IBS bytes are handled (and logged) here, never returned. */
int hci_recv(struct hci *h, struct hci_pkt *p, unsigned ms);

/*
 * Send a command and wait for its Command Complete (rsp = return parameters, status first) or a
 * failing Command Status. Returns the status byte (0 = success), -1 timeout, -2 send failed.
 */
int hci_cmd(struct hci *h, uint16_t op, const uint8_t *p, uint8_t n, uint8_t *rsp, size_t *rlen, unsigned ms);

/*
 * Send a command (op != 0) and wait for event evt whose payload starts with match[0..mlen) (mlen 0 =
 * any). The payload goes to rsp. A Command Complete for op with a non-zero status, or a failing
 * Command Status, ends the wait with that status. Returns 0, the failing status, -1 timeout, -2 send.
 */
int hci_cmd_ev(struct hci *h, uint16_t op, const uint8_t *p, uint8_t n, uint8_t evt, const uint8_t *match,
	size_t mlen, uint8_t *rsp, size_t *rlen, unsigned ms);
/* the same without sending anything */
int hci_wait_ev(struct hci *h, uint8_t evt, const uint8_t *match, size_t mlen, uint8_t *rsp, size_t *rlen,
	unsigned ms);
/* read and log whatever arrives for ms */
void hci_drain(struct hci *h, unsigned ms);

const char *hci_op_name(uint16_t op);
#endif
