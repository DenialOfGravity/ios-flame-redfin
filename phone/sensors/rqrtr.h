/*
 * /dev/redwood-qrtr (kernel 0956, WS-D; ABI fixed in docs/redfin/qol-plan.md §3.1):
 *   open()                 one QRTR port on our node, O_NONBLOCK honoured
 *   ioctl RQRTR_LOOKUP     service (+instance) -> node/port of the ADSP's server (0 = none yet)
 *   write()/read()         struct { u32 node; u32 port; u8 data[]; }: one datagram each
 * plus sysctl kern.sweet_adsp_services ("svc:inst@node:port,...").
 *
 * The same framing works over any datagram fd (a SOCK_SEQPACKET socketpair in the host tests), so the
 * functions take an fd and never assume it is the device.
 */
#ifndef RQRTR_H
#define RQRTR_H
#include <stdint.h>
#include <stddef.h>
#include <sys/ioctl.h>

#define RQRTR_DEV "/dev/redwood-qrtr"
struct rqrtr_lookup {
	uint32_t service, instance, node, port;
};
#define RQRTR_LOOKUP _IOWR('q', 1, struct rqrtr_lookup)
#define RQRTR_MAX 65536

int rqrtr_open(void);		/* O_RDWR | O_NONBLOCK; -1 + errno */
int rqrtr_lookup(int fd, uint32_t service, uint32_t *node, uint32_t *port);	/* 0, or -1 (none / no ioctl) */
int rqrtr_send(int fd, uint32_t node, uint32_t port, const void *data, size_t len);
/* Waits up to timeout_ms (0: poll once, <0: forever) for one datagram. Returns its length, 0 on timeout,
 * -1 on error. */
int rqrtr_recv(int fd, uint32_t *node, uint32_t *port, uint8_t *data, size_t cap, int timeout_ms);
/* The kernel's service list (kern.sweet_adsp_services), or NULL. */
const char *rqrtr_services(void);

#endif
