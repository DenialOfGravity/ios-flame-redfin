/*
 * The byte pipe to the WCN3998's HCI UART (QUPv3 wrapper 0 SE5, 0x894000). Two backends:
 *   geni.c      the SE's FIFOs polled from userland through /dev/pmem (stage 1a, no kernel help)
 *   uart_dev.c  /dev/btuart (kernel patch 0981, boot-arg btuart=1): SPI 606 interrupt, RX ring
 * and the fake controller of the host test (tlv_test.c).
 */
#ifndef BT_UART_H
#define BT_UART_H
#include <stddef.h>
#include <stdint.h>

struct uart {
	const char *name;
	unsigned baud;
	int flow;
	/* host baud (the controller is told separately); restarts RX */
	int (*set_baud)(struct uart *u, unsigned baud);
	/* 1: RTS/CTS hardware flow control; 0: CTS ignored and RTS held "not ready"
	   (hci_uart_set_flow_control(hu, true) in Linux: the power pulses and baud changes) */
	int (*set_flow)(struct uart *u, int on);
	/* all of buf into the TX FIFO; -1 on timeout (CTS never ready) */
	int (*write)(struct uart *u, const uint8_t *buf, size_t n);
	/* until the last byte left the shifter, at most ms */
	int (*drain)(struct uart *u, unsigned ms);
	/* whatever arrived, up to n bytes, waiting at most ms for the first one; 0 = nothing */
	int (*read)(struct uart *u, uint8_t *buf, size_t n, unsigned ms);
	void (*flush_rx)(struct uart *u);
	void (*close)(struct uart *u);
	void *priv;
};

/*
 * geni.c: SE5 over /dev/pmem: clocks, pins, then GENI_FW_REVISION_RO must say protocol 2 (UART firmware
 * loaded by XBL), else NULL. oversampling 16 or 32 (0 = from the QUP version, as Linux).
 */
struct uart *geni_open(int verbose, int oversampling);
/* uart_dev.c: /dev/btuart, NULL if absent */
struct uart *btuart_open(int verbose);

/* power.c: the BT rails (RPMh VRM votes through /dev/pmem, added to wland's, never removed) */
int bt_rails_on(int verbose);
/* TLMM GPIO 73 (SW_CTRL, an output of the chip): 0/1, -1 if unreadable */
int bt_sw_ctrl(void);

uint64_t now_ms(void);
#endif
