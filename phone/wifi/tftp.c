/*
 * TFTP over QRTR (service 4096), as github.com/andersson/tqftpserv: the
 * modem reads its user-PD images (wlanmdsp.mbn) and writes small state
 * files this way. Each transfer gets its own port. RRQ options: blksize,
 * timeoutms, tsize, rsize (bytes to read), seek (offset), wsize (blocks per
 * ACK).
 */
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "link.h"
#include "tftp.h"

#define RO_PREFIX	"/readonly/firmware/image/"
#define RW_PREFIX	"/readwrite/"
#define FW_DIR		"/var/local/fw/modem"
#define RW_DIR		"/var/local/fw/rw"

enum { OP_RRQ = 1, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR, OP_OACK };

static struct xfer {
	int used, write, fd;
	uint32_t node, port;		/* the client */
	uint32_t blksize, wsize;
	uint64_t seek, rsize, size;	/* rsize 0: to the end */
	uint32_t last_sent;		/* block number */
	int done;
	int pending;			/* an ACK that came in while a window was going out */
	uint16_t pending_blk;
} xf[TFTP_XFERS];
int tftp_verbose = 0;

int tftp_init(void)
{
	mkdir(RW_DIR, 0755);
	if (qrtr_new_server(TFTP_SERVICE, 1, 0, TFTP_PORT))
		return -1;
	printf("tftp: serving at %u:%x\n", QRTR_NODE_APPS, TFTP_PORT);
	return 0;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xff; }
static uint16_t get16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

static void send_pkt(int i, const uint8_t *b, uint32_t n)
{
	qrtr_send(QRTR_TYPE_DATA, TFTP_XFER_PORT0 + i, xf[i].node, xf[i].port, b, n);
}

static void send_error(uint32_t sport, uint32_t node, uint32_t port, uint16_t code, const char *msg)
{
	uint8_t b[128];
	put16(b, OP_ERROR);
	put16(b + 2, code);
	size_t l = strlen(msg) + 1;
	memcpy(b + 4, msg, l);
	qrtr_send(QRTR_TYPE_DATA, sport, node, port, b, (uint32_t)(4 + l));
}

static void xfer_close(int i)
{
	if (xf[i].fd >= 0)
		close(xf[i].fd);
	xf[i].used = 0;
}

/* data block blk (1-based); returns its length */
static uint32_t send_block(int i, uint32_t blk)
{
	static uint8_t b[4 + 65536];
	struct xfer *x = &xf[i];
	uint64_t off = (uint64_t)(blk - 1) * x->blksize;
	uint64_t end = x->rsize ? x->rsize : (x->size > x->seek ? x->size - x->seek : 0);
	uint32_t len = off >= end ? 0 : (uint32_t)(end - off < x->blksize ? end - off : x->blksize);
	put16(b, OP_DATA);
	put16(b + 2, (uint16_t)blk);
	ssize_t r = len ? pread(x->fd, b + 4, len, (off_t)(x->seek + off)) : 0;
	if (r < 0)
		r = 0;
	send_pkt(i, b, (uint32_t)(4 + r));
	x->last_sent = blk;
	if ((uint32_t)r < x->blksize)
		x->done = 1;
	return (uint32_t)r;
}

static void send_window(int i, uint32_t acked)
{
	struct xfer *x = &xf[i];
	for (uint32_t k = 0; k < x->wsize && !x->done; k++)
		send_block(i, acked + 1 + k);
}

static int open_path(const char *path, int write)
{
	char p[256];
	if (!strncmp(path, RO_PREFIX, strlen(RO_PREFIX))) {
		const char *rest = path + strlen(RO_PREFIX);
		const char *base = strrchr(rest, '/');
		snprintf(p, sizeof(p), FW_DIR "/%s", base ? base + 1 : rest);
		for (char *c = p + strlen(FW_DIR) + 1; *c; c++)
			*c = (char)tolower((unsigned char)*c);
		return write ? -1 : open(p, O_RDONLY);
	}
	if (!strncmp(path, RW_PREFIX, strlen(RW_PREFIX))) {
		snprintf(p, sizeof(p), RW_DIR "/%s", path + strlen(RW_PREFIX));
		for (char *c = p + strlen(RW_DIR) + 1; *c; c++)
			if (*c == '/')
				*c = '_';
		return write ? open(p, O_RDWR | O_CREAT | O_TRUNC, 0644) : open(p, O_RDONLY);
	}
	return -1;
}

static void request(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n, int write)
{
	char buf[512];
	if (n > sizeof(buf) - 1)
		n = sizeof(buf) - 1;
	memcpy(buf, d, n);
	buf[n] = 0;
	const char *file = buf + 2, *end = buf + n;
	const char *mode = file + strlen(file) + 1;
	int i;
	for (i = 0; i < TFTP_XFERS && xf[i].used; i++)
		;
	if (i == TFTP_XFERS) {
		send_error(TFTP_PORT, h->src_node, h->src_port, 0, "busy");
		return;
	}
	struct xfer *x = &xf[i];
	memset(x, 0, sizeof(*x));
	x->node = h->src_node;
	x->port = h->src_port;
	x->blksize = 512;
	x->wsize = 1;
	x->write = write;
	uint8_t oack[512];
	size_t on = 2;
	put16(oack, OP_OACK);
	int nopts = 0;
	char tsize_s[24] = "";
	const char *o = mode < end ? mode + strlen(mode) + 1 : end;
	x->fd = open_path(file, write);
	struct stat st;
	if (x->fd >= 0 && !fstat(x->fd, &st))
		x->size = (uint64_t)st.st_size;
	printf("tftp: %s \"%s\" (%s)%s", write ? "write" : "read", file, mode, x->fd < 0 ? " -> not found" : "");
	while (o < end && *o) {
		const char *k = o, *v = o + strlen(o) + 1;
		if (v >= end)
			break;
		printf(" %s=%s", k, v);
		uint64_t val = strtoull(v, NULL, 0);
		const char *echo = v;
		char blk_s[16];
		if (!strcmp(k, "blksize")) {
			/*
			 * Blocks that fit the modem's reusable GLINK intents (1152 bytes, with the
			 * QRTR and TFTP headers): bigger ones need a one-shot intent each, ~30 ms
			 * per round trip, which the client's 200 ms timeout does not survive.
			 */
			uint32_t max = getenv("TFTP_BLKSIZE") ? (uint32_t)atoi(getenv("TFTP_BLKSIZE")) : TFTP_MAX_BLKSIZE;
			x->blksize = (uint32_t)(val > max ? max : val);
			snprintf(blk_s, sizeof(blk_s), "%u", x->blksize);
			echo = blk_s;
		}
		else if (!strcmp(k, "wsize"))
			x->wsize = val ? (uint32_t)val : 1;
		else if (!strcmp(k, "rsize"))
			x->rsize = val;
		else if (!strcmp(k, "seek"))
			x->seek = val;
		else if (!strcmp(k, "tsize")) {
			snprintf(tsize_s, sizeof(tsize_s), "%llu", (unsigned long long)x->size);
			echo = tsize_s;
		}
		size_t kl = strlen(k) + 1, el = strlen(echo) + 1;
		if (on + kl + el < sizeof(oack)) {
			memcpy(oack + on, k, kl);
			memcpy(oack + on + kl, echo, el);
			on += kl + el;
			nopts++;
		}
		o = v + strlen(v) + 1;
	}
	printf("\n");
	if (x->fd < 0) {
		send_error(TFTP_PORT, h->src_node, h->src_port, 1, "file not found");
		return;
	}
	if (x->rsize && x->seek + x->rsize > x->size)
		x->rsize = x->size > x->seek ? x->size - x->seek : 0;
	x->used = 1;
	if (nopts) {
		send_pkt(i, oack, (uint32_t)on);	/* the client ACKs block 0 */
	} else if (write) {
		uint8_t a[4];
		put16(a, OP_ACK);
		put16(a + 2, 0);
		send_pkt(i, a, 4);
	} else {
		send_window(i, 0);
	}
}

void tftp_handle(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n)
{
	if (n < 4)
		return;
	uint16_t op = get16(d);
	if (h->dst_port == TFTP_PORT) {
		if (op == OP_RRQ || op == OP_WRQ)
			request(h, d, n, op == OP_WRQ);
		return;
	}
	int i = (int)(h->dst_port - TFTP_XFER_PORT0);
	if (i < 0 || i >= TFTP_XFERS || !xf[i].used)
		return;
	struct xfer *x = &xf[i];
	uint16_t blk = get16(d + 2);
	if (tftp_verbose)
		printf("[%6llu] tftp: xfer %d op %u blk %u (sent %u)\n", (unsigned long long)link_ms(), i, op, blk, x->last_sent);
	if (op == OP_ACK && !x->write) {
		/*
		 * Sending a block can wait for a GLINK intent, and that wait handles what comes
		 * in, this ACK path included: note the ACK and let the outer call act on it.
		 */
		static int in_window;
		if (in_window) {
			x->pending = 1;
			x->pending_blk = blk;
			return;
		}
		in_window = 1;
	again:
		if (x->done && blk == (uint16_t)x->last_sent) {
			printf("tftp: read done (%u blocks; intents: done %u reuse %u requested %u, %u ms waiting)\n", x->last_sent,
			       link_stats[0], link_stats[1], link_stats[2], link_stats[3]);
			xfer_close(i);
		} else {
			/* the window's end, or a repeated ACK (client timeout): go on from the block after it */
			uint32_t acked = x->last_sent - (uint16_t)(x->last_sent - blk);	/* 16-bit block numbers */
			if (acked != x->last_sent)
				printf("tftp: resend after block %u (sent %u)\n", acked, x->last_sent);
			x->done = 0;
			send_window(i, acked);
		}
		if (x->used && x->pending) {
			x->pending = 0;
			blk = x->pending_blk;
			goto again;
		}
		in_window = 0;
	} else if (op == OP_DATA && x->write) {
		uint32_t len = n - 4;
		pwrite(x->fd, d + 4, len, (off_t)((uint64_t)(blk - 1) * x->blksize));
		uint8_t a[4];
		put16(a, OP_ACK);
		put16(a + 2, blk);
		send_pkt(i, a, 4);
		if (len < x->blksize) {
			printf("tftp: write done (%u blocks)\n", blk);
			xfer_close(i);
		}
	} else if (op == OP_ERROR) {
		printf("tftp: client error %u: %.*s (block %u; intents: done %u reuse %u requested %u, %u ms waiting)\n", blk,
		       (int)(n - 4), (const char *)d + 4, x->last_sent, link_stats[0], link_stats[1], link_stats[2], link_stats[3]);
		xfer_close(i);
	}
}
