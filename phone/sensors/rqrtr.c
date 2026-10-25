#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#include "rqrtr.h"

static uint8_t frame[8 + RQRTR_MAX];

int rqrtr_open(void)
{
	return open(RQRTR_DEV, O_RDWR | O_NONBLOCK);
}

int rqrtr_lookup(int fd, uint32_t service, uint32_t *node, uint32_t *port)
{
	struct rqrtr_lookup l = { service, 0, 0, 0 };
	if (ioctl(fd, RQRTR_LOOKUP, &l) != 0 || (l.node == 0 && l.port == 0))
		return -1;
	*node = l.node;
	*port = l.port;
	return 0;
}

int rqrtr_send(int fd, uint32_t node, uint32_t port, const void *data, size_t len)
{
	if (len > RQRTR_MAX)
		return -1;
	memcpy(frame, &node, 4);
	memcpy(frame + 4, &port, 4);
	memcpy(frame + 8, data, len);
	ssize_t n = write(fd, frame, 8 + len);
	return n == (ssize_t)(8 + len) ? 0 : -1;
}

static long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/*
 * poll() first; a character device without a select routine reports "ready" every time (or POLLNVAL),
 * so after a ready-but-EAGAIN the wait falls back to 2 ms sleeps for the rest of the process.
 */
static int poll_unreliable;

int rqrtr_recv(int fd, uint32_t *node, uint32_t *port, uint8_t *data, size_t cap, int timeout_ms)
{
	long deadline = timeout_ms < 0 ? -1 : now_ms() + timeout_ms;
	for (;;) {
		ssize_t n = read(fd, frame, sizeof(frame));
		if (n >= 8) {
			size_t len = (size_t)n - 8;
			memcpy(node, frame, 4);
			memcpy(port, frame + 4, 4);
			if (len > cap)
				len = cap;
			memcpy(data, frame + 8, len);
			return (int)len;
		}
		if (n >= 0 && n < 8)
			return -1;	/* runt datagram, or EOF of a host-test socketpair */
		if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
			return -1;
		long left = deadline < 0 ? 1000 : deadline - now_ms();
		if (left <= 0)
			return 0;
		if (!poll_unreliable) {
			struct pollfd p = { fd, POLLIN, 0 };
			int r = poll(&p, 1, (int)(left > 1000 ? 1000 : left));
			if (r < 0 && errno != EINTR)
				poll_unreliable = 1;
			else if (r > 0 && (p.revents & (POLLNVAL | POLLERR)))
				poll_unreliable = 1;
			else if (r > 0) {
				n = read(fd, frame, sizeof(frame));
				if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
					poll_unreliable = 1;	/* "ready" with nothing to read */
					continue;
				}
				if (n >= 8) {
					size_t len = (size_t)n - 8;
					memcpy(node, frame, 4);
					memcpy(port, frame + 4, 4);
					if (len > cap)
						len = cap;
					memcpy(data, frame + 8, len);
					return (int)len;
				}
				if (n == 0)	/* the other end of a host-test socketpair went away */
					return -1;
			}
		} else {
			struct timespec ts = { 0, 2000000 };
			nanosleep(&ts, NULL);
		}
	}
}

const char *rqrtr_services(void)
{
#ifdef __APPLE__
	static char buf[1024];
	size_t len = sizeof(buf) - 1;
	if (sysctlbyname("kern.sweet_adsp_services", buf, &len, NULL, 0) != 0)
		return NULL;
	buf[len < sizeof(buf) ? len : sizeof(buf) - 1] = 0;
	return buf;
#else
	return NULL;
#endif
}
