/* struct uart over /dev/btuart (0981). */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "uart.h"
#include "btuart.h"

struct dev {
	struct uart u;
	int fd;
	unsigned timeout;
};

static int d_set_baud(struct uart *u, unsigned baud)
{
	struct dev *d = u->priv;
	uint32_t b = baud;
	if (ioctl(d->fd, BTUART_SET_BAUD, &b) < 0) {
		printf("btd: /dev/btuart baud %u: %s\n", baud, strerror(errno));
		return -1;
	}
	u->baud = baud;
	return 0;
}

static int d_set_flow(struct uart *u, int on)
{
	struct dev *d = u->priv;
	uint32_t f = (uint32_t)on;
	u->flow = on;
	return ioctl(d->fd, BTUART_SET_FLOW, &f) < 0 ? -1 : 0;
}

static int d_write(struct uart *u, const uint8_t *buf, size_t n)
{
	struct dev *d = u->priv;
	while (n) {
		ssize_t w = write(d->fd, buf, n);
		if (w < 0) {
			if (errno == EINTR)
				continue;
			printf("btd: /dev/btuart write: %s\n", strerror(errno));
			return -1;
		}
		buf += w;
		n -= (size_t)w;
	}
	return 0;
}

static int d_drain(struct uart *u, unsigned ms)
{
	struct dev *d = u->priv;
	uint32_t t = ms;
	return ioctl(d->fd, BTUART_DRAIN, &t) < 0 ? -1 : 0;
}

static int d_read(struct uart *u, uint8_t *buf, size_t n, unsigned ms)
{
	struct dev *d = u->priv;
	if (ms != d->timeout) {
		uint32_t t = ms ? ms : 1;	/* 0 would mean "forever" to the driver */
		ioctl(d->fd, BTUART_TIMEOUT, &t);
		d->timeout = ms;
	}
	ssize_t r = read(d->fd, buf, n);
	if (r < 0)
		return errno == EAGAIN || errno == EINTR ? 0 : -1;
	return (int)r;
}

static void d_flush(struct uart *u)
{
	struct dev *d = u->priv;
	ioctl(d->fd, BTUART_FLUSH);
}

static void d_close(struct uart *u)
{
	struct dev *d = u->priv;
	struct btuart_stats s;
	if (ioctl(d->fd, BTUART_STATS, &s) == 0)
		printf("btd: /dev/btuart closed: %u Bd, irqs %u, rx %llu tx %llu bytes, overruns %u, parity/break %u, "
			"ring full %u, tx timeouts %u\n", s.baud, s.irqs, (unsigned long long)s.rx_bytes,
			(unsigned long long)s.tx_bytes, s.rx_overruns, s.rx_parity_break, s.ring_full, s.tx_timeouts);
	close(d->fd);
	free(d);
}

struct uart *btuart_open(int verbose)
{
	int fd = open("/dev/btuart", O_RDWR);
	if (fd < 0) {
		if (errno != ENOENT)
			printf("btd: /dev/btuart: %s\n", strerror(errno));
		return NULL;
	}
	struct dev *d = calloc(1, sizeof(*d));
	d->fd = fd;
	d->u.name = "/dev/btuart";
	d->u.set_baud = d_set_baud;
	d->u.set_flow = d_set_flow;
	d->u.write = d_write;
	d->u.drain = d_drain;
	d->u.read = d_read;
	d->u.flush_rx = d_flush;
	d->u.close = d_close;
	d->u.priv = d;
	d->u.baud = 115200;
	d->u.flow = 1;
	struct btuart_stats s;
	if (ioctl(fd, BTUART_STATS, &s) == 0)
		printf("btd: /dev/btuart: SE5 fw %#x (protocol %u), QUP %#x, %u Bd, oversampling %u, irqs so far %u\n",
			s.fw_revision, (s.fw_revision >> 8) & 0xff, s.qup_version, s.baud, s.oversampling, s.irqs);
	(void)verbose;
	return &d->u;
}
