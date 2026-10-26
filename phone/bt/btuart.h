/*
 * /dev/btuart (kernel patch 0981, bsd/dev/sweet_geniuart.c, boot-arg btuart=1): the WCN3998 HCI UART
 * (QUPv3 wrapper 0 SE5) with its GIC SPI 606 interrupt. One opener at a time. The kernel file carries a
 * copy of these definitions; keep both in step.
 *
 *   open    clocks, pins, GENI FIFO mode at 115200 8N1 with RTS/CTS; ENXIO if SE5 has no UART firmware
 *   read    whatever is buffered (16 KiB ring), waiting up to the read timeout for the first byte;
 *           EAGAIN when nothing came (or at once with O_NONBLOCK)
 *   write   blocks until every byte is in the TX FIFO; ETIMEDOUT if CTS stays "not ready" for 1 s
 *   close   RX stays running into the ring until the next open flushes it; interrupts masked
 */
#ifndef BT_BTUART_H
#define BT_BTUART_H
#include <stdint.h>
#include <sys/ioccom.h>

struct btuart_stats {
	uint32_t fw_revision;		/* GENI_FW_REVISION_RO */
	uint32_t qup_version;
	uint32_t baud, flow, oversampling, src_hz, divider;
	uint32_t irqs, rx_overruns, rx_parity_break, ring_full, tx_timeouts;
	uint64_t rx_bytes, tx_bytes;
};

#define BTUART_SET_BAUD	_IOW('B', 1, uint32_t)	/* host side only; restarts RX */
#define BTUART_SET_FLOW	_IOW('B', 2, uint32_t)	/* 1 RTS/CTS; 0 CTS ignored + RTS held not-ready */
#define BTUART_DRAIN	_IOW('B', 3, uint32_t)	/* wait up to N ms until the TX side is idle */
#define BTUART_FLUSH	_IO('B', 4)		/* drop buffered RX */
#define BTUART_TIMEOUT	_IOW('B', 5, uint32_t)	/* read timeout in ms (default 100, 0 = forever) */
#define BTUART_STATS	_IOR('B', 6, struct btuart_stats)
#define BTUART_SET_OS	_IOW('B', 7, uint32_t)	/* UART oversampling 16 or 32; re-applies the baud */
#endif
