/*
 * FlameBridge: a macOS app bundle that relays local TCP ports to the phone
 * over the USB Ethernet link (192.168.7.2). It exists because macOS Local
 * Network privacy blocks unicast to LAN hosts from processes whose
 * responsible app never asked for the permission (the terminal here has no
 * NSLocalNetworkUsageDescription, so macOS never prompts and denies
 * silently). This bundle has the key, so macOS asks once; connections to
 * 127.0.0.1 are never blocked.
 *
 * TCP forwards come from ports.txt next to the app ("LOCAL REMOTE" per
 * line; default 2222 -> 22) so the app never needs rebuilding: a rebuild
 * changes its code signature and macOS may forget the permission.
 *   UDP 127.0.0.1:5142 -> 192.168.7.2:5141 (command server, unicast)
 *
 * Log: /tmp/flamebridge.log. Start: open tools/flamebridge/FlameBridge.app
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>

#include <limits.h>
#include <mach-o/dyld.h>

#define PHONE "192.168.7.2"

/* ports.txt next to FlameBridge.app (the executable is FlameBridge.app/Contents/MacOS/FlameBridge) */
static FILE *open_ports_file(void)
{
	char exe[PATH_MAX], path[PATH_MAX];
	uint32_t len = sizeof(exe);
	if (_NSGetExecutablePath(exe, &len) != 0 || !realpath(exe, path))
		return NULL;
	for (int i = 0; i < 4; i++) {
		char *s = strrchr(path, '/');
		if (s)
			*s = 0;
	}
	strlcat(path, "/ports.txt", sizeof(path));
	return fopen(path, "r");
}

static FILE *logf;

static void lg(const char *fmt, const char *a, int b)
{
	fprintf(logf, fmt, a, b);
	fflush(logf);
}

struct pair { int a, b; };

static void *pump(void *arg)
{
	struct pair *p = arg;
	char buf[65536];
	for (;;) {
		fd_set r;
		FD_ZERO(&r);
		FD_SET(p->a, &r);
		FD_SET(p->b, &r);
		if (select((p->a > p->b ? p->a : p->b) + 1, &r, NULL, NULL, NULL) < 0)
			break;
		int from = FD_ISSET(p->a, &r) ? p->a : p->b, to = from == p->a ? p->b : p->a;
		ssize_t n = read(from, buf, sizeof(buf));
		if (n <= 0)
			break;
		for (ssize_t off = 0; off < n;) {
			ssize_t w = write(to, buf + off, n - off);
			if (w <= 0)
				goto done;
			off += w;
		}
	}
done:
	close(p->a);
	close(p->b);
	free(p);
	return NULL;
}

struct fwd { int lport, rport; };

static void *tcp_listener(void *arg)
{
	struct fwd *f = arg;
	int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in la = { .sin_family = AF_INET, .sin_port = htons(f->lport) };
	la.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(ls, (struct sockaddr *)&la, sizeof(la)) || listen(ls, 8)) {
		lg("listen %s %d failed\n", "127.0.0.1", f->lport);
		return NULL;
	}
	for (;;) {
		int c = accept(ls, NULL, NULL);
		if (c < 0)
			continue;
		int r = socket(AF_INET, SOCK_STREAM, 0);
		struct sockaddr_in ra = { .sin_family = AF_INET, .sin_port = htons(f->rport) };
		inet_pton(AF_INET, PHONE, &ra.sin_addr);
		if (connect(r, (struct sockaddr *)&ra, sizeof(ra))) {
			lg("connect %s:%d failed\n", PHONE, f->rport);
			close(c);
			close(r);
			continue;
		}
		lg("relay 127.0.0.1 -> %s:%d\n", PHONE, f->rport);
		struct pair *p = malloc(sizeof(*p));
		p->a = c;
		p->b = r;
		pthread_t t;
		pthread_create(&t, NULL, pump, p);
		pthread_detach(t);
	}
}

static void *udp_relay(void *arg)
{
	(void)arg;
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in la = { .sin_family = AF_INET, .sin_port = htons(5142) };
	la.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	bind(s, (struct sockaddr *)&la, sizeof(la));
	struct sockaddr_in ra = { .sin_family = AF_INET, .sin_port = htons(5141) };
	inet_pton(AF_INET, PHONE, &ra.sin_addr);
	char buf[2048];
	for (;;) {
		ssize_t n = recv(s, buf, sizeof(buf), 0);
		if (n > 0)
			sendto(socket(AF_INET, SOCK_DGRAM, 0), buf, n, 0, (struct sockaddr *)&ra, sizeof(ra));
	}
}

int main(void)
{
	logf = fopen("/tmp/flamebridge.log", "a");
	lg("FlameBridge started (%s, pid %d)\n", PHONE, getpid());
	/* Touch the local network once at start so macOS shows its prompt. */
	int probe = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in ra = { .sin_family = AF_INET, .sin_port = htons(9) };
	inet_pton(AF_INET, PHONE, &ra.sin_addr);
	if (sendto(probe, "x", 1, 0, (struct sockaddr *)&ra, sizeof(ra)) < 0)
		lg("probe: %s (%d)\n", strerror(errno), errno);
	else
		lg("probe: sent to %s:%d\n", PHONE, 9);
	static struct fwd fwds[32] = { { 2222, 22 } };
	unsigned nf = 1;
	FILE *pf = open_ports_file();
	if (pf) {
		nf = 0;
		int l, r;
		char line[128];
		while (nf < 32 && fgets(line, sizeof(line), pf))
			if (sscanf(line, "%d %d", &l, &r) == 2) {
				fwds[nf].lport = l;
				fwds[nf++].rport = r;
			}
		fclose(pf);
	}
	pthread_t t;
	for (unsigned i = 0; i < nf; i++) {
		lg("forward 127.0.0.1:%s -> %d\n", "", fwds[i].lport);
		pthread_create(&t, NULL, tcp_listener, &fwds[i]);
	}
	pthread_create(&t, NULL, udp_relay, NULL);
	for (;;)
		pause();
}
