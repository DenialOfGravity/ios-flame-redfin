/*
 * sweetmon: low-overhead monitor daemon for the redfin port (design and wire protocol: docs/redfin/sweetmon.md).
 *
 *   sweetmon [-D] [-p PORT] [-k TOKEN | -K] [-l LOGFILE] [-v]
 *   sweetmon -Z IN OUT      compress IN into the LZ4 frame format the daemon sends (test of the writer)
 *
 *   -D        daemonize (double fork, setsid, stdio to /dev/null)
 *   -p PORT   TCP port (default 5150, all interfaces)
 *   -k TOKEN  auth token (default: first line of /var/local/sweetmon.key, hex); -K: no auth (tests only)
 *   -l FILE   debug log (default none: nothing is written to flash)
 *   -v        verbose (debug log to stderr when not daemonized)
 *
 * One process, single-threaded event loop (poll) with timers; one worker thread only while a trace or a pmem read
 * runs. One authenticated client at a time (a new authenticated client replaces the old one). Frames: u32 LE len
 * (bytes after it) + u8 type + payload. Phone -> PC: H hello, S sample, K klog, R reply, T trace chunk, E trace end,
 * F frame stats, P speed filler. PC -> phone: C command line.
 *
 * kdebug traces are byte-compatible with phone/tools/sweettrace.c (ws-u-lab: header, kd_buf events, thread map,
 * the -F/-f reduction), sent as one LZ4 frame (independent 4 MiB blocks, no checksums) in T chunks of <= 1 MiB.
 * kdebug is always released (KERN_KDREMOVE) on stop, abort, client loss, SIGTERM and exit.
 */
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#else
typedef struct { uint32_t numer, denom; } mach_timebase_info_data_t;
uint64_t mach_absolute_time(void);
void mach_timebase_info(mach_timebase_info_data_t *t);
#endif
#include "lz4/lz4.h"

#ifndef SWEETMON_VERSION
#define SWEETMON_VERSION __DATE__
#endif

#define KEYFILE         "/var/local/sweetmon.key"
#define PMEM_DEV        "/dev/pmem"
#define MAX_FRAME       (4u << 20)
#define CMD_MAX         4096
#define NCONN           5               /* the active client + pending (unauthenticated) ones */
#define Q_PRODUCE       (1u << 20)      /* T, K and P frames are made only while less than this is queued */
#define Q_DROP          (2u << 20)      /* S and F frames are dropped above this */
#define T_CHUNK         (1u << 20)
#define K_PIECE         (256u << 10)
#define KLOG_RING       (4ull << 20)
#define KLOG_POLL_MS    250
#define PEND_TIMEOUT_MS 10000

/* ------------------------------------------------------------------------------------------------ util */

static int verbose, daemonized;
static FILE *logf;
static mach_timebase_info_data_t tb;

static uint64_t abs_now(void) { return mach_absolute_time(); }
static uint64_t abs_to_ns(uint64_t a) { return (uint64_t)((__uint128_t)a * tb.numer / tb.denom); }
static uint64_t now_ms(void) { return abs_to_ns(abs_now()) / 1000000ull; }

static void dbg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void dbg(const char *fmt, ...)
{
	if (logf == NULL && !(verbose && !daemonized))
		return;
	char m[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(m, sizeof(m), fmt, ap);
	va_end(ap);
	struct timeval tv;
	gettimeofday(&tv, NULL);
	if (logf != NULL) {
		fprintf(logf, "%ld.%03d %s\n", (long)tv.tv_sec, (int)(tv.tv_usec / 1000), m);
		fflush(logf);
	}
	if (verbose && !daemonized)
		fprintf(stderr, "sweetmon: %s\n", m);
}

/* ------------------------------------------------------------------------------------------------ JSON */

struct jb { char *p; size_t n, cap; };

static void jb_reserve(struct jb *j, size_t more)
{
	if (j->n + more + 1 <= j->cap)
		return;
	size_t c = j->cap ? j->cap : 4096;
	while (c < j->n + more + 1)
		c *= 2;
	char *q = realloc(j->p, c);
	if (q == NULL)
		abort();
	j->p = q;
	j->cap = c;
}

static void jb_pf(struct jb *j, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void jb_pf(struct jb *j, const char *fmt, ...)
{
	for (;;) {
		jb_reserve(j, 64);
		va_list ap;
		va_start(ap, fmt);
		int w = vsnprintf(j->p + j->n, j->cap - j->n, fmt, ap);
		va_end(ap);
		if (w < 0)
			return;
		if ((size_t)w < j->cap - j->n) {
			j->n += (size_t)w;
			return;
		}
		jb_reserve(j, (size_t)w + 1);
	}
}

/* length of the valid UTF-8 sequence at s (n bytes left), 0 if invalid */
static size_t utf8_len(const unsigned char *s, size_t n)
{
	size_t l = s[0] >= 0xf0 && s[0] <= 0xf4 ? 4 : s[0] >= 0xe0 ? 3 : s[0] >= 0xc2 && s[0] < 0xe0 ? 2 : 0;
	if (l == 0 || l > n)
		return 0;
	for (size_t i = 1; i < l; i++)
		if ((s[i] & 0xc0) != 0x80)
			return 0;
	return l;
}

/* a JSON string (quoted, escaped; invalid UTF-8 -> U+FFFD) of at most max bytes of s */
static void jb_str(struct jb *j, const char *s, size_t max)
{
	const unsigned char *u = (const unsigned char *)s;
	size_t n = strnlen(s, max);
	jb_reserve(j, n * 6 + 2);
	char *o = j->p + j->n;
	*o++ = '"';
	for (size_t i = 0; i < n; i++) {
		unsigned char c = u[i];
		if (c == '"' || c == '\\') {
			*o++ = '\\';
			*o++ = (char)c;
		} else if (c < 0x20) {
			const char *e = c == '\n' ? "\\n" : c == '\t' ? "\\t" : c == '\r' ? "\\r" : NULL;
			if (e != NULL) {
				memcpy(o, e, 2);
				o += 2;
			} else {
				o += snprintf(o, 7, "\\u%04x", c);
			}
		} else if (c < 0x80) {
			*o++ = (char)c;
		} else {
			size_t l = utf8_len(u + i, n - i);
			if (l == 0) {
				memcpy(o, "\\ufffd", 6);
				o += 6;
			} else {
				memcpy(o, u + i, l);
				o += l;
				i += l - 1;
			}
		}
	}
	*o++ = '"';
	j->n = (size_t)(o - j->p);
	j->p[j->n] = 0;
}

/* ------------------------------------------------------------------------------------------------ LZ4 frame writer */

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void wr32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
static uint32_t rotl32(uint32_t x, int r) { return x << r | x >> (32 - r); }

static uint32_t xxh32(const uint8_t *p, size_t n, uint32_t seed)
{
	const uint32_t P1 = 2654435761u, P2 = 2246822519u, P3 = 3266489917u, P4 = 668265263u, P5 = 374761393u;
	size_t i = 0;
	uint32_t h;
	if (n >= 16) {
		uint32_t v1 = seed + P1 + P2, v2 = seed + P2, v3 = seed, v4 = seed - P1;
		for (; i + 16 <= n; i += 16) {
			v1 = rotl32(v1 + rd32(p + i) * P2, 13) * P1;
			v2 = rotl32(v2 + rd32(p + i + 4) * P2, 13) * P1;
			v3 = rotl32(v3 + rd32(p + i + 8) * P2, 13) * P1;
			v4 = rotl32(v4 + rd32(p + i + 12) * P2, 13) * P1;
		}
		h = rotl32(v1, 1) + rotl32(v2, 7) + rotl32(v3, 12) + rotl32(v4, 18);
	} else {
		h = seed + P5;
	}
	h += (uint32_t)n;
	for (; i + 4 <= n; i += 4)
		h = rotl32(h + rd32(p + i) * P3, 17) * P4;
	for (; i < n; i++)
		h = rotl32(h + p[i] * P5, 11) * P1;
	h ^= h >> 15;
	h *= P2;
	h ^= h >> 13;
	h *= P3;
	h ^= h >> 16;
	return h;
}

#define LZF_BLOCK       (4u << 20)      /* BD 7 */
struct zout { uint8_t *p; size_t n, cap; int err; };
struct lzf { struct zout *o; uint8_t *blk; size_t fill; uint64_t raw; const atomic_int *cancel; };

static int zout_reserve(struct zout *o, size_t more)
{
	if (o->err)
		return -1;
	if (o->n + more <= o->cap)
		return 0;
	size_t c = o->cap ? o->cap : (1u << 20);
	while (c < o->n + more)
		c *= 2;
	uint8_t *q = realloc(o->p, c);
	if (q == NULL) {
		o->err = 1;
		return -1;
	}
	o->p = q;
	o->cap = c;
	return 0;
}

static int lzf_block(struct lzf *z, const uint8_t *src, size_t n)
{
	if (z->cancel != NULL && atomic_load(z->cancel))
		return -1;
	int bound = LZ4_compressBound((int)n);
	if (zout_reserve(z->o, (size_t)bound + 8) < 0)
		return -1;
	uint8_t *hdr = z->o->p + z->o->n;
	int c = LZ4_compress_default((const char *)src, (char *)hdr + 4, (int)n, bound);
	if (c <= 0 || (size_t)c >= n) {
		wr32(hdr, 0x80000000u | (uint32_t)n);
		memcpy(hdr + 4, src, n);
		z->o->n += 4 + n;
	} else {
		wr32(hdr, (uint32_t)c);
		z->o->n += 4 + (size_t)c;
	}
	return 0;
}

static int lzf_begin(struct lzf *z, struct zout *o, const atomic_int *cancel)
{
	memset(z, 0, sizeof(*z));
	z->o = o;
	z->cancel = cancel;
	z->blk = malloc(LZF_BLOCK);
	if (z->blk == NULL || zout_reserve(o, 7) < 0)
		return -1;
	uint8_t *h = o->p + o->n;
	wr32(h, 0x184D2204u);
	h[4] = 0x60;            /* version 01, blocks independent, no checksums, no content size */
	h[5] = 0x70;            /* block max 4 MiB */
	h[6] = (uint8_t)(xxh32(h + 4, 2, 0) >> 8);
	o->n += 7;
	return 0;
}

static int lzf_write(struct lzf *z, const void *p, size_t n)
{
	const uint8_t *s = p;
	z->raw += n;
	while (n > 0) {
		if (z->fill == 0 && n >= LZF_BLOCK) {   /* whole blocks straight from the source */
			if (lzf_block(z, s, LZF_BLOCK) < 0)
				return -1;
			s += LZF_BLOCK;
			n -= LZF_BLOCK;
			continue;
		}
		size_t m = LZF_BLOCK - z->fill < n ? LZF_BLOCK - z->fill : n;
		memcpy(z->blk + z->fill, s, m);
		z->fill += m;
		s += m;
		n -= m;
		if (z->fill == LZF_BLOCK) {
			if (lzf_block(z, z->blk, z->fill) < 0)
				return -1;
			z->fill = 0;
		}
	}
	return 0;
}

static int lzf_end(struct lzf *z)
{
	int r = 0;
	if (z->fill > 0 && lzf_block(z, z->blk, z->fill) < 0)
		r = -1;
	if (r == 0 && zout_reserve(z->o, 4) == 0) {
		wr32(z->o->p + z->o->n, 0);
		z->o->n += 4;
	} else {
		r = -1;
	}
	free(z->blk);
	z->blk = NULL;
	return r;
}

/* ------------------------------------------------------------------------------------------------ kdebug (sweettrace) */

#ifndef KERN_KDEBUG
#define KERN_KDEBUG             24
#endif
#define KERN_KDEFLAGS           1
#define KERN_KDENABLE           3
#define KERN_KDSETBUF           4
#define KERN_KDGETBUF           5
#define KERN_KDSETUP            6
#define KERN_KDREMOVE           7
#define KERN_KDREADTR           10
#define KERN_KDTHRMAP           12
#define KERN_KDREADCURTHRMAP    21
#define KERN_KDSET_TYPEFILTER   22
#define KDEBUG_ENABLE_TRACE     0x1
#define KDBG_WRAPPED            0x0008
#define TYPEFILTER_SIZE         8192

#define DBG_MACH                1
#define DBG_MACH_EXCP_SC        0x0c
#define DBG_MACH_EXCP_INTR      0x05
#define DBG_MACH_IPC            0x20
#define DBG_MACH_SCHED          0x40
#define DBG_BSD                 4
#define DBG_BSD_EXCP_SC         0x0c
#define DBG_DRIVERS             6
#define DBG_TRACE               7
#define SWEET_SUBCLASS          0xF5

typedef struct {
	uint64_t timestamp;
	uint64_t arg1, arg2, arg3, arg4, arg5;
	uint32_t debugid;
	uint32_t cpuid;
	uint64_t unused;
} kd_buf;

typedef struct {
	int nkdbufs;
	int nolog;
	unsigned int flags;
	int nkdthreads;
	int bufid;
} kbufinfo_t;

typedef struct {
	uint64_t thread;
	int valid;
	char command[20];
} kd_threadmap;

#define SWT_MAGIC       "SWTRACE1"
struct swt_header {
	char     magic[8];
	uint32_t version, header_size;
	uint32_t tb_numer, tb_denom;
	uint64_t start_abs, end_abs;
	uint64_t n_events;
	uint32_t n_threads, ncpu;
	uint32_t kd_flags;
	uint32_t kbufs;
	uint32_t reads, dropped;
	int32_t  tracer_pid;
	uint32_t read_ms;
	uint64_t start_wall_ns;
	char     args[128];
};
struct swt_thread {
	uint64_t tid;
	int32_t  pid;
	uint32_t flags;
	char     comm[32];
	char     name[64];
};
_Static_assert(sizeof(kd_buf) == 64, "kd_buf");
_Static_assert(sizeof(struct swt_header) == 216, "swt_header");
_Static_assert(sizeof(struct swt_thread) == 112, "swt_thread");

/* sweettrace -F (ws-u-lab), kept in step with tools-claude/swtr-reduce.py; only used by the worker thread */
#define SWT_CODE(c, s, n)       ((uint32_t)(c) << 24 | (uint32_t)(s) << 16 | (uint32_t)(n) << 2)
#define SWT_SCHED               SWT_CODE(1, 0x40, 0x00)
#define SWT_HANDOFF             SWT_CODE(1, 0x40, 0x02)
#define SWT_MKRUN               SWT_CODE(1, 0x40, 0x06)
#define SWT_INTR                SWT_CODE(1, 0x05, 0)
#define SWT_KMSG                SWT_CODE(1, 0x20, 0x0a)
#define SWT_MSG_SEND            SWT_CODE(1, 0x20, 0x03)
#define SWT_MSG_RECV            SWT_CODE(1, 0x20, 0x04)
#define SWT_MSG_RECV_NV         SWT_CODE(1, 0x20, 0x05)
#define SWT_SW_BASE             ((6u << 24) | (0xF5u << 16))

static uint8_t swt_whole[TYPEFILTER_SIZE];

static int swt_always(uint32_t dbg)
{
	uint32_t cid = dbg & 0xfffffffcu;
	return (dbg & 0xffff0000u) == SWT_SW_BASE || cid == SWT_KMSG || (dbg >> 24) == 7 || cid == SWT_INTR;
}

static int swt_whole_csc(uint32_t dbg)
{
	uint32_t csc = dbg >> 16;
	return (swt_whole[csc / 8] >> (csc % 8)) & 1;
}

static int swt_prekeep(uint32_t dbg)
{
	uint32_t cid = dbg & 0xfffffffcu;
	return swt_always(dbg) || cid == SWT_MKRUN || cid == SWT_MSG_SEND || cid == SWT_MSG_RECV || cid == SWT_MSG_RECV_NV ||
	    cid == SWT_SCHED || cid == SWT_HANDOFF || swt_whole_csc(dbg);
}

static size_t swt_prefilter(kd_buf *buf, size_t n)
{
	size_t w = 0;
	for (size_t i = 0; i < n; i++)
		if (swt_prekeep(buf[i].debugid)) {
			if (w != i)
				buf[w] = buf[i];
			w++;
		}
	return w;
}

static int u64cmp(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return x < y ? -1 : x > y;
}

static const kd_buf *swt_sort_base;
static int swt_idx_cmp(const void *a, const void *b)
{
	uint32_t i = *(const uint32_t *)a, j = *(const uint32_t *)b;
	uint64_t x = swt_sort_base[i].timestamp, y = swt_sort_base[j].timestamp;
	if (x != y)
		return x < y ? -1 : 1;
	return i < j ? -1 : i > j;
}

static int swt_sort(kd_buf *e, uint64_t n)
{
	uint64_t i;
	for (i = 1; i < n && e[i - 1].timestamp <= e[i].timestamp; i++) {
	}
	if (i >= n)
		return 0;
	uint32_t *idx = malloc(n * sizeof(uint32_t));
	kd_buf *tmp = malloc(n * sizeof(kd_buf));
	if (idx == NULL || tmp == NULL) {
		free(idx);
		free(tmp);
		return -1;
	}
	for (i = 0; i < n; i++)
		idx[i] = (uint32_t)i;
	swt_sort_base = e;
	qsort(idx, n, sizeof(uint32_t), swt_idx_cmp);
	for (i = 0; i < n; i++)
		tmp[i] = e[idx[i]];
	memcpy(e, tmp, n * sizeof(kd_buf));
	free(idx);
	free(tmp);
	return 1;
}

static int in_set(const uint64_t *set, size_t n, uint64_t v)
{
	return n && bsearch(&v, set, n, sizeof(uint64_t), u64cmp) != NULL;
}

static uint64_t swt_reduce(kd_buf *e, uint64_t n, const struct swt_thread *t, uint32_t nt, const char *procs, uint32_t *nfocus)
{
	uint64_t *focus = malloc((nt + 1) * sizeof(uint64_t));
	size_t nf = 0;
	char *list = strdup(procs);
	for (uint32_t k = 0; focus != NULL && list != NULL && k < nt; k++) {
		char comm[sizeof(t[k].comm) + 1];
		memcpy(comm, t[k].comm, sizeof(t[k].comm));
		comm[sizeof(t[k].comm)] = 0;
		size_t cl = strlen(comm);
		for (const char *p = list; *p;) {
			const char *q = strchr(p, ',');
			size_t l = q ? (size_t)(q - p) : strlen(p);
			if (l == cl && strncmp(p, comm, l) == 0) {
				focus[nf++] = t[k].tid;
				break;
			}
			p += l + (q != NULL);
		}
	}
	free(list);
	if (focus != NULL)
		qsort(focus, nf, sizeof(uint64_t), u64cmp);
	size_t u = 0;
	for (size_t k = 0; k < nf; k++)
		if (u == 0 || focus[u - 1] != focus[k])
			focus[u++] = focus[k];
	nf = u;
	*nfocus = (uint32_t)nf;
	swt_sort(e, n);
	enum { NCPU_MAX = 4096 };
	static uint64_t cpu_cur[NCPU_MAX];
	static uint8_t cpu_has[NCPU_MAX];
	memset(cpu_has, 0, sizeof(cpu_has));
	uint64_t w = 0;
	for (uint64_t i = 0; i < n; i++) {
		uint32_t dbg = e[i].debugid, cid = dbg & 0xfffffffcu;
		int keep = swt_always(dbg) || swt_whole_csc(dbg);
		if (cid == SWT_MKRUN)
			keep |= in_set(focus, nf, e[i].arg1);
		else if (cid == SWT_MSG_SEND || cid == SWT_MSG_RECV || cid == SWT_MSG_RECV_NV)
			keep |= in_set(focus, nf, e[i].arg5);
		else if (cid == SWT_SCHED || cid == SWT_HANDOFF) {
			uint32_t c = e[i].cpuid < NCPU_MAX ? e[i].cpuid : NCPU_MAX - 1;
			uint64_t old = cpu_has[c] ? cpu_cur[c] : e[i].arg5, nw = e[i].arg2;
			if (old != nw && (in_set(focus, nf, old) || in_set(focus, nf, nw)))
				keep = 1;
			cpu_cur[c] = nw;
			cpu_has[c] = 1;
		}
		if (keep)
			e[w++] = e[i];
	}
	free(focus);
	return w;
}

static void tf_allow(uint8_t *tf, unsigned cls, int sub)
{
	if (sub < 0) {
		memset(tf + cls * 32, 0xff, 32);
	} else {
		unsigned csc = cls << 8 | (unsigned)sub;
		tf[csc / 8] |= (uint8_t)(1u << (csc % 8));
	}
}

/* ------------------------------------------------------------------------------------------------ platform */

/* libproc / sys/proc_info.h: not in the iOS SDK */
#define PROC_ALL_PIDS           1
#define PROC_PIDTASKINFO        4
#define PROC_PIDTHREADID64INFO  15
#define PROC_PIDLISTTHREADIDS   28
struct proc_taskinfo {
	uint64_t pti_virtual_size, pti_resident_size, pti_total_user, pti_total_system, pti_threads_user, pti_threads_system;
	int32_t pti_policy, pti_faults, pti_pageins, pti_cow_faults, pti_messages_sent, pti_messages_received,
	    pti_syscalls_mach, pti_syscalls_unix, pti_csw, pti_threadnum, pti_numrunning, pti_priority;
};
struct proc_threadinfo {
	uint64_t pth_user_time, pth_system_time;
	int32_t pth_cpu_usage, pth_policy, pth_run_state, pth_flags, pth_sleep_time, pth_curpri, pth_priority,
	    pth_maxpriority;
	char pth_name[64];
};
struct pinfo { int pid; char comm[32]; };

#ifdef __APPLE__
int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

static int kd(int op, int value, void *buf, size_t *len)
{
	int mib[4] = { CTL_KERN, KERN_KDEBUG, op, value };
	size_t l0 = 0;
	int withval = op == KERN_KDEFLAGS || op == KERN_KDENABLE || op == KERN_KDSETBUF;
	return sysctl(mib, withval ? 4 : 3, buf, len ? len : &l0, NULL, 0);
}

static struct pinfo *procs(int *n)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;
	*n = 0;
	if (sysctl(mib, 3, NULL, &len, NULL, 0) < 0)
		return NULL;
	len += 64 * sizeof(struct kinfo_proc);
	struct kinfo_proc *kp = malloc(len);
	if (kp == NULL || sysctl(mib, 3, kp, &len, NULL, 0) < 0) {
		free(kp);
		return NULL;
	}
	int c = (int)(len / sizeof(*kp));
	struct pinfo *p = calloc((size_t)c + 1, sizeof(*p));
	for (int i = 0; p != NULL && i < c; i++) {
		p[i].pid = kp[i].kp_proc.p_pid;
		strlcpy(p[i].comm, kp[i].kp_proc.p_comm, sizeof(p[i].comm));
	}
	free(kp);
	*n = p != NULL ? c : 0;
	return p;
}

static mach_port_t host_port;
static int ncpu_now(void) { int n = 0; size_t l = sizeof(n); sysctlbyname("hw.ncpu", &n, &l, NULL, 0); return n; }

/* per-core ticks [user, sys, idle, nice]; returns cores */
static int cpu_ticks(uint32_t (*t)[4], int max)
{
	natural_t n = 0;
	processor_info_array_t info = NULL;
	mach_msg_type_number_t cnt = 0;
	if (host_processor_info(host_port, PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) != KERN_SUCCESS)
		return 0;
	processor_cpu_load_info_t l = (processor_cpu_load_info_t)info;
	int k = (int)n < max ? (int)n : max;
	for (int i = 0; i < k; i++) {
		t[i][0] = l[i].cpu_ticks[CPU_STATE_USER];
		t[i][1] = l[i].cpu_ticks[CPU_STATE_SYSTEM];
		t[i][2] = l[i].cpu_ticks[CPU_STATE_IDLE];
		t[i][3] = l[i].cpu_ticks[CPU_STATE_NICE];
	}
	vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
	return k;
}

struct vmst { uint64_t free, active, inactive, wired, compressed, spec, pageins, swapins, faults; uint32_t page_kb; };
static int vm_stats(struct vmst *v)
{
	vm_statistics64_data_t s;
	mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
	memset(v, 0, sizeof(*v));
	if (host_statistics64(host_port, HOST_VM_INFO64, (host_info64_t)&s, &c) != KERN_SUCCESS)
		return -1;
	vm_size_t ps = 0;
	host_page_size(host_port, &ps);
	v->free = s.free_count;
	v->active = s.active_count;
	v->inactive = s.inactive_count;
	v->wired = s.wire_count;
	v->compressed = s.compressor_page_count;
	v->spec = s.speculative_count;
	v->pageins = s.pageins;
	v->swapins = s.swapins;
	v->faults = s.faults;
	v->page_kb = (uint32_t)(ps / 1024);
	return 0;
}

static uint64_t self_rss_kb(void)
{
	mach_task_basic_info_data_t bi;
	mach_msg_type_number_t c = MACH_TASK_BASIC_INFO_COUNT;
	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&bi, &c) != KERN_SUCCESS)
		return 0;
	return bi.resident_size / 1024;
}

static int64_t boottime_s(void)
{
	struct timeval bt = { 0, 0 };
	size_t l = sizeof(bt);
	int mib[2] = { CTL_KERN, KERN_BOOTTIME };
	if (sysctl(mib, 2, &bt, &l, NULL, 0) < 0)
		return 0;
	return bt.tv_sec;
}

static void plat_init(void) { host_port = mach_host_self(); }

#else /* host build (Linux): stubs so the protocol, klog (file as /dev/pmem), pmem and a fake kdebug can be tested */

#define strlcpy(d, s, n) snprintf((d), (n), "%s", (s))
uint64_t mach_absolute_time(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
void mach_timebase_info(mach_timebase_info_data_t *t) { t->numer = 1; t->denom = 1; }
#define RUSAGE_INFO_V4 4
struct rusage_info_v4 {
	uint64_t ri_user_time, ri_system_time, ri_pkg_idle_wkups, ri_interrupt_wkups, ri_phys_footprint,
	    ri_proc_start_abstime, ri_diskio_bytesread, ri_diskio_byteswritten;
};
typedef void *rusage_info_t;
static int proc_listpids(uint32_t type, uint32_t ti, void *b, int sz)
{
	(void)type; (void)ti;
	if (b == NULL)
		return (int)sizeof(int);
	if (sz < (int)sizeof(int))
		return 0;
	*(int *)b = getpid();
	return (int)sizeof(int);
}
static int proc_pidinfo(int pid, int flavor, uint64_t arg, void *b, int sz)
{
	(void)pid; (void)arg;
	if (flavor == PROC_PIDTASKINFO && sz >= (int)sizeof(struct proc_taskinfo)) {
		memset(b, 0, sizeof(struct proc_taskinfo));
		((struct proc_taskinfo *)b)->pti_threadnum = 2;
		return (int)sizeof(struct proc_taskinfo);
	}
	return 0;
}
static int proc_name(int pid, void *b, uint32_t sz) { (void)pid; return snprintf(b, sz, "sweetmon\"host"); }
static int proc_pid_rusage(int pid, int flavor, rusage_info_t *b)
{
	(void)pid; (void)flavor;
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	struct rusage_info_v4 *r = (struct rusage_info_v4 *)b;
	memset(r, 0, sizeof(*r));
	r->ri_user_time = (uint64_t)ru.ru_utime.tv_sec * 1000000000ull + (uint64_t)ru.ru_utime.tv_usec * 1000ull;
	r->ri_system_time = (uint64_t)ru.ru_stime.tv_sec * 1000000000ull + (uint64_t)ru.ru_stime.tv_usec * 1000ull;
	r->ri_phys_footprint = (uint64_t)ru.ru_maxrss * 1024;
	return 0;
}
static struct pinfo *procs(int *n)
{
	struct pinfo *p = calloc(2, sizeof(*p));
	p[0].pid = getpid();
	strlcpy(p[0].comm, "sweetmon", sizeof(p[0].comm));
	*n = 1;
	return p;
}
/* fake kdebug: each read returns 2000 events (sched switches between two threads, some 0xF5 SHOWN/VSYNC/GPU_DONE) */
static uint64_t fk_ts = 1000;
static int fk_enabled;
static int kd(int op, int value, void *buf, size_t *len)
{
	switch (op) {
	case KERN_KDENABLE: fk_enabled = value; return 0;
	case KERN_KDGETBUF: {
		kbufinfo_t *bi = buf;
		memset(bi, 0, sizeof(*bi));
		bi->nkdbufs = 65536;
		bi->nkdthreads = 2;
		return 0;
	}
	case KERN_KDTHRMAP: case KERN_KDREADCURTHRMAP: {
		kd_threadmap *m = buf;
		if (*len < 2 * sizeof(*m))
			return errno = EINVAL, -1;
		memset(m, 0, 2 * sizeof(*m));
		m[0].thread = 0x111; m[0].valid = 77; strlcpy(m[0].command, "backboardd", sizeof(m[0].command));
		m[1].thread = 0x222; m[1].valid = 88; strlcpy(m[1].command, "Preferences", sizeof(m[1].command));
		*len = 2 * sizeof(*m);
		return 0;
	}
	case KERN_KDREADTR: {
		size_t cap = *len / sizeof(kd_buf), n = fk_enabled ? (cap < 2000 ? cap : 2000) : 0;
		kd_buf *e = buf;
		for (size_t i = 0; i < n; i++) {
			memset(&e[i], 0, sizeof(e[i]));
			e[i].timestamp = fk_ts += 1000;
			switch (i % 5) {
			case 0: e[i].debugid = SWT_SCHED; e[i].arg2 = (i & 1) ? 0x111 : 0x333; e[i].arg5 = 0x222; break;
			case 1: e[i].debugid = SWT_CODE(6, 0xF5, 0x07); e[i].arg1 = fk_ts - 5000000; break;
			case 2: e[i].debugid = SWT_CODE(6, 0xF5, 0x01); break;
			case 3: e[i].debugid = SWT_CODE(6, 0xF5, 0x11); e[i].arg2 = 100; e[i].arg3 = 100 + 19200 * (i % 7); break;
			default: e[i].debugid = SWT_CODE(1, 0x31, 1); e[i].arg5 = 0x444; break; /* dropped by -f */
			}
			e[i].cpuid = (uint32_t)(i % 8);
		}
		*len = n;
		return 0;
	}
	default: return 0;
	}
}
static int ncpu_now(void) { return 8; }
static int cpu_ticks(uint32_t (*t)[4], int max)
{
	static uint32_t k;
	k += 10;
	for (int i = 0; i < max && i < 8; i++) {
		t[i][0] = k * (uint32_t)(i + 1); t[i][1] = k; t[i][2] = 100 * k; t[i][3] = 0;
	}
	return max < 8 ? max : 8;
}
struct vmst { uint64_t free, active, inactive, wired, compressed, spec, pageins, swapins, faults; uint32_t page_kb; };
static int vm_stats(struct vmst *v) { memset(v, 0, sizeof(*v)); v->page_kb = 16; return 0; }
static uint64_t self_rss_kb(void) { struct rusage ru; getrusage(RUSAGE_SELF, &ru); return (uint64_t)ru.ru_maxrss; }
static int64_t boottime_s(void) { return (int64_t)time(NULL) - (int64_t)(mach_absolute_time() / 1000000000ull); }
static int sysctlnametomib(const char *n, int *mib, size_t *l) { (void)n; (void)mib; (void)l; return errno = ENOENT, -1; }
static int sysctl(int *mib, unsigned l, void *o, size_t *ol, void *n, size_t nl) { (void)mib; (void)l; (void)o; (void)ol; (void)n; (void)nl; return -1; }
static void plat_init(void) {}
#endif

/* threads of every process (as sweettrace's map_names) */
static struct swt_thread *thr;
static uint32_t nthr, capthr;
static struct swt_thread thr_spare;
static struct swt_thread *thr_get(uint64_t tid)
{
	for (uint32_t i = 0; i < nthr; i++)
		if (thr[i].tid == tid)
			return &thr[i];
	if (nthr == capthr) {
		uint32_t c = capthr ? 2 * capthr : 4096;
		struct swt_thread *n = realloc(thr, c * sizeof(*thr));
		if (n == NULL)
			return memset(&thr_spare, 0, sizeof(thr_spare));
		thr = n;
		capthr = c;
	}
	memset(&thr[nthr], 0, sizeof(thr[nthr]));
	thr[nthr].tid = tid;
	thr[nthr].pid = -1;
	return &thr[nthr++];
}

static void map_kdebug(const kd_threadmap *m, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		if (m[i].thread == 0)
			continue;
		struct swt_thread *t = thr_get(m[i].thread);
		t->flags |= 1;
		if (t->pid < 0)
			t->pid = strncmp(m[i].command, "kernel_task", sizeof(m[i].command)) == 0 ? 0 : m[i].valid;
		if (t->comm[0] == 0) {
			memcpy(t->comm, m[i].command, sizeof(m[i].command) < sizeof(t->comm) ? sizeof(m[i].command) : sizeof(t->comm));
			t->comm[sizeof(t->comm) - 1] = 0;
		}
	}
}

static void map_names(void)
{
	int np = 0;
	struct pinfo *p = procs(&np);
	uint64_t *ids = malloc(4096 * sizeof(uint64_t));
	for (int i = 0; p != NULL && ids != NULL && i < np; i++) {
		int got = proc_pidinfo(p[i].pid, PROC_PIDLISTTHREADIDS, 0, ids, 4096 * (int)sizeof(uint64_t));
		for (int k = 0; got > 0 && k < got / (int)sizeof(uint64_t); k++) {
			struct proc_threadinfo ti;
			memset(&ti, 0, sizeof(ti));
			struct swt_thread *t = thr_get(ids[k]);
			t->flags |= 2;
			t->pid = p[i].pid;
			strlcpy(t->comm, p[i].comm, sizeof(t->comm));
			if (proc_pidinfo(p[i].pid, PROC_PIDTHREADID64INFO, ids[k], &ti, sizeof(ti)) == (int)sizeof(ti) && ti.pth_name[0])
				strlcpy(t->name, ti.pth_name, sizeof(t->name));
		}
	}
	free(ids);
	free(p);
}

static int kd_info(kbufinfo_t *bi)
{
	size_t l = sizeof(*bi);
	memset(bi, 0, sizeof(*bi));
	return kd(KERN_KDGETBUF, 0, bi, &l);
}

/* ------------------------------------------------------------------------------------------------ connections */

struct qbuf { struct qbuf *next; size_t len, off; uint8_t d[]; };
struct conn {
	int fd, authed, bad;
	uint64_t since_ms;
	uint8_t rx[CMD_MAX + 8];
	size_t rxn;
	struct qbuf *qh, *qt;
	size_t queued;
	int dead;
	char peer[48];
};
static struct conn conns[NCONN];
static struct conn *cl;                 /* the active (authenticated) client */
static uint64_t tx_bytes, k_bytes, dropped_frames;

static void conn_flush(struct conn *c)
{
	while (c->qh != NULL && !c->dead) {
		struct qbuf *q = c->qh;
		ssize_t w = write(c->fd, q->d + q->off, q->len - q->off);
		if (w < 0) {
			if (errno == EINTR)
				continue;
			if (errno != EAGAIN && errno != EWOULDBLOCK)
				c->dead = 1;
			return;
		}
		q->off += (size_t)w;
		c->queued -= (size_t)w;
		tx_bytes += (uint64_t)w;
		if (q->off == q->len) {
			c->qh = q->next;
			if (c->qh == NULL)
				c->qt = NULL;
			free(q);
		}
	}
}

/* a frame of type with payload a + b; droppable frames (S, F) are dropped when the client is slow */
static int send_frame(struct conn *c, uint8_t type, const void *a, size_t an, const void *b, size_t bn, int droppable)
{
	if (c == NULL || c->dead)
		return -1;
	if (droppable && c->queued > Q_DROP) {
		dropped_frames++;
		return -1;
	}
	size_t n = 5 + an + bn;
	struct qbuf *q = malloc(sizeof(*q) + n);
	if (q == NULL)
		return -1;
	q->next = NULL;
	q->len = n;
	q->off = 0;
	wr32(q->d, (uint32_t)(n - 4));
	q->d[4] = type;
	if (an)
		memcpy(q->d + 5, a, an);
	if (bn)
		memcpy(q->d + 5 + an, b, bn);
	if (c->qt != NULL)
		c->qt->next = q;
	else
		c->qh = q;
	c->qt = q;
	c->queued += n;
	conn_flush(c);
	return 0;
}

static void send_json(struct conn *c, uint8_t type, struct jb *j, int droppable)
{
	send_frame(c, type, j->p, j->n, NULL, 0, droppable);
}

static struct jb rj;                    /* reply buffer */
/* R reply; extra: JSON members (",\"k\":v...") or NULL */
static void reply(struct conn *c, const char *cmd, int ok, const char *extra, const char *fmt, ...) __attribute__((format(printf, 5, 6)));
static void reply(struct conn *c, const char *cmd, int ok, const char *extra, const char *fmt, ...)
{
	char m[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(m, sizeof(m), fmt, ap);
	va_end(ap);
	rj.n = 0;
	jb_pf(&rj, "{\"cmd\":");
	jb_str(&rj, cmd, 64);
	jb_pf(&rj, ",\"ok\":%s,\"msg\":", ok ? "true" : "false");
	jb_str(&rj, m, sizeof(m));
	if (extra != NULL)
		jb_pf(&rj, "%s", extra);
	jb_pf(&rj, "}");
	send_json(c, 'R', &rj, 0);
}

/* ------------------------------------------------------------------------------------------------ state */

static const char *token;               /* NULL: no auth (-K) */
static unsigned rate_ms = 1000, topevery = 2, topn = 15;
static uint64_t t_start_abs;
static volatile sig_atomic_t sig_stop;
static int sigpipe_fd[2] = { -1, -1 }, wpipe[2] = { -1, -1 };
static int quit_req;

static int pmem_fd = -1;
static const char *pmem_dev = PMEM_DEV;
static int pmem_open(void)
{
	if (pmem_fd < 0)
		pmem_fd = open(pmem_dev, O_RDONLY | O_CLOEXEC);
	return pmem_fd;
}

static int pmem_read(uint64_t pa, void *buf, size_t n)
{
	uint8_t *b = buf;
	while (n > 0) {
		ssize_t r = pread(pmem_fd, b, n, (off_t)pa);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		b += r;
		n -= (size_t)r;
		pa += (uint64_t)r;
	}
	return 0;
}

/* klog */
static struct { int on; uint64_t pa, pos, total, total_prev, total_t_ms; uint64_t next_ms; } kl;

static int klog_total(uint64_t *t) { return pmem_read(kl.pa, t, 8); }

static int ring_read(uint64_t pos, uint8_t *buf, size_t n)
{
	uint64_t off = pos % KLOG_RING;
	size_t a = KLOG_RING - off < n ? (size_t)(KLOG_RING - off) : n;
	if (pmem_read(kl.pa + 8 + off, buf, a) < 0)
		return -1;
	return a < n ? pmem_read(kl.pa + 8, buf + a, n - a) : 0;
}

static uint8_t *kbuf;
/* send klog bytes [pos, total) while there is room in the queue */
static void klog_pump(void)
{
	if (!kl.on || cl == NULL || !cl->authed)
		return;
	if (kbuf == NULL && (kbuf = malloc(8 + K_PIECE)) == NULL)
		return;
	for (int round = 0; round < 32 && cl->queued < Q_PRODUCE && kl.pos < kl.total; round++) {
		if (kl.total - kl.pos > KLOG_RING)
			kl.pos = kl.total - KLOG_RING;
		uint64_t n = kl.total - kl.pos;
		if (n > K_PIECE)
			n = K_PIECE;
		uint64_t off = kl.pos % KLOG_RING;
		if (n > KLOG_RING - off)
			n = KLOG_RING - off;
		if (ring_read(kl.pos, kbuf + 8, (size_t)n) < 0) {
			dbg("klog: pmem read failed at pos %llu: %s", (unsigned long long)kl.pos, strerror(errno));
			return;
		}
		uint64_t t2 = 0;
		if (klog_total(&t2) == 0 && t2 > kl.pos + KLOG_RING) {   /* the kernel overwrote the start meanwhile */
			uint64_t skip = t2 - KLOG_RING - kl.pos;
			kl.total = t2;
			if (skip >= n) {
				kl.pos = t2 - KLOG_RING;
				continue;
			}
			memmove(kbuf + 8, kbuf + 8 + skip, (size_t)(n - skip));
			kl.pos += skip;
			n -= skip;
		}
		memcpy(kbuf, &kl.pos, 8);
		send_frame(cl, 'K', kbuf, 8 + (size_t)n, NULL, 0, 0);
		k_bytes += n;
		kl.pos += n;
	}
}

static void klog_poll(void)
{
	uint64_t t;
	if (kl.on && klog_total(&t) == 0 && t <= (1ull << 40))
		kl.total = t;
}

/* ------------------------------------------------------------------------------------------------ sampler */

#define NCPU_MAX 16
static const char *temp_names[] = { "silver", "gold", "prime", "cpuss", "gpu", "ddr", "camera", "npu", "aoss", "max" };
#define NTEMP (sizeof(temp_names) / sizeof(temp_names[0]))
static int temp_mib[NTEMP][4];
static size_t temp_miblen[NTEMP];

static void temps_resolve(void)
{
	for (size_t i = 0; i < NTEMP; i++) {
		char n[64];
		snprintf(n, sizeof(n), "kern.sweet_temp_%s", temp_names[i]);
		temp_miblen[i] = 4;
		if (sysctlnametomib(n, temp_mib[i], &temp_miblen[i]) < 0)
			temp_miblen[i] = 0;
	}
}

struct pent { int pid; uint64_t start, cpu, wk, io, fp; };
static struct pent *pcur, *pprev;
static size_t npcur, npprev, pcap;
static int *pidbuf;
static size_t pidcap;
static uint64_t ptab_abs;               /* time of the previous process table */

static int pent_cmp(const void *a, const void *b)
{
	const struct pent *x = a, *y = b;
	return x->pid < y->pid ? -1 : x->pid > y->pid;
}

struct prow { int pid; double cpu_ms; uint64_t wk, fp_kb, io_kb; };
static int prow_cmp(const void *a, const void *b)
{
	const struct prow *x = a, *y = b;
	return x->cpu_ms < y->cpu_ms ? 1 : x->cpu_ms > y->cpu_ms ? -1 : (x->pid > y->pid) - (x->pid < y->pid);
}

static double ticks_ms(uint64_t t) { return (double)t * tb.numer / tb.denom / 1e6; }

/* appends ,"procs":[...],"nproc":N */
static void proc_table(struct jb *j, int with_rows)
{
	int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
	if (bytes <= 0)
		return;
	size_t want = (size_t)bytes / sizeof(int) + 64;
	if (want > pidcap) {
		int *n = realloc(pidbuf, want * sizeof(int));
		if (n == NULL)
			return;
		pidbuf = n;
		pidcap = want;
	}
	bytes = proc_listpids(PROC_ALL_PIDS, 0, pidbuf, (int)(pidcap * sizeof(int)));
	if (bytes <= 0)
		return;
	size_t np = (size_t)bytes / sizeof(int);
	if (np > pcap) {
		struct pent *a = realloc(pcur, np * sizeof(*a)), *b = a ? realloc(pprev, np * sizeof(*b)) : NULL;
		if (a != NULL)
			pcur = a;
		if (b == NULL)
			return;
		pprev = b;
		pcap = np;
	}
	npcur = 0;
	int seen0 = 0;
	for (size_t i = 0; i < np; i++) {
		struct rusage_info_v4 ri;
		if (pidbuf[i] < 0 || (pidbuf[i] == 0 && seen0++))	/* pid 0 (kernel_task) once */
			continue;
		if (proc_pid_rusage(pidbuf[i], RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0)
			continue;
		struct pent *e = &pcur[npcur++];
		e->pid = pidbuf[i];
		e->start = ri.ri_proc_start_abstime;
		e->cpu = ri.ri_user_time + ri.ri_system_time;
		e->wk = ri.ri_interrupt_wkups + ri.ri_pkg_idle_wkups;
		e->io = ri.ri_diskio_bytesread + ri.ri_diskio_byteswritten;
		e->fp = ri.ri_phys_footprint;
	}
	qsort(pcur, npcur, sizeof(*pcur), pent_cmp);
	uint64_t now = abs_now();
	if (with_rows && topn > 0) {
		struct prow *rows = malloc((npcur + 1) * sizeof(*rows));
		size_t nr = 0;
		for (size_t i = 0; rows != NULL && i < npcur; i++) {
			struct pent *e = &pcur[i], *p = bsearch(e, pprev, npprev, sizeof(*e), pent_cmp);
			int same = p != NULL && p->start == e->start;
			rows[nr].pid = e->pid;
			rows[nr].cpu_ms = ticks_ms(same ? e->cpu - p->cpu : (ptab_abs ? e->cpu : 0));
			rows[nr].wk = same ? e->wk - p->wk : 0;
			rows[nr].io_kb = (same ? e->io - p->io : 0) / 1024;
			rows[nr].fp_kb = e->fp / 1024;
			nr++;
		}
		if (rows != NULL) {
			qsort(rows, nr, sizeof(*rows), prow_cmp);
			jb_pf(j, ",\"procs_dt_ms\":%.0f,\"procs\":[", ptab_abs ? ticks_ms(now - ptab_abs) : 0.0);
			for (size_t i = 0; i < nr && i < topn; i++) {
				char name[2 * 17 + 1] = "";
				struct proc_taskinfo ti;
				int threads = -1;
				if (proc_name(rows[i].pid, name, sizeof(name)) <= 0)
					name[0] = 0;
				if (proc_pidinfo(rows[i].pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) == (int)sizeof(ti))
					threads = ti.pti_threadnum;
				jb_pf(j, "%s[%d,", i ? "," : "", rows[i].pid);
				jb_str(j, name, sizeof(name));
				jb_pf(j, ",%.1f,%llu,%llu,%d,%llu]", rows[i].cpu_ms, (unsigned long long)rows[i].wk,
				    (unsigned long long)rows[i].fp_kb, threads, (unsigned long long)rows[i].io_kb);
			}
			jb_pf(j, "]");
		}
		free(rows);
	}
	jb_pf(j, ",\"nproc\":%zu", npcur);
	struct pent *t = pprev;
	pprev = pcur;
	pcur = t;
	npprev = npcur;
	ptab_abs = now;
}

static struct {
	uint64_t abs;
	uint32_t cpu[NCPU_MAX][4];
	int ncpu;
	struct vmst vm;
	uint64_t self_us, tx, kbytes, ktotal;
	unsigned n;
} sp;                                   /* previous sample */
static uint64_t next_sample_ms;
static struct jb sj;

static uint64_t self_cpu_us(void)
{
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	return (uint64_t)(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000000ull + (uint64_t)(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec);
}

static void sample_base(void)
{
	sp.abs = abs_now();
	sp.ncpu = cpu_ticks(sp.cpu, NCPU_MAX);
	vm_stats(&sp.vm);
	sp.self_us = self_cpu_us();
	sp.tx = tx_bytes;
	sp.kbytes = k_bytes;
}

static void sample(void)
{
	uint64_t now = abs_now();
	double dt = ticks_ms(now - sp.abs), ds = dt > 0 ? dt / 1000 : 1;
	struct jb *j = &sj;
	j->n = 0;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	jb_pf(j, "{\"t\":%llu,\"up\":%.1f,\"dt_ms\":%.0f,\"cpu\":[", (unsigned long long)abs_to_ns(now),
	    (double)tv.tv_sec + tv.tv_usec / 1e6 - (double)boottime_s(), dt);
	uint32_t c[NCPU_MAX][4];
	int nc = cpu_ticks(c, NCPU_MAX);
	for (int i = 0; i < nc; i++)
		jb_pf(j, "%s[%u,%u,%u,%u]", i ? "," : "", c[i][0] - sp.cpu[i][0], c[i][1] - sp.cpu[i][1], c[i][2] - sp.cpu[i][2],
		    c[i][3] - sp.cpu[i][3]);
	memcpy(sp.cpu, c, sizeof(c));
	jb_pf(j, "],\"temp\":{");
	int first = 1;
	for (size_t i = 0; i < NTEMP; i++) {
		int v;
		size_t l = sizeof(v);
		if (temp_miblen[i] && sysctl(temp_mib[i], (unsigned)temp_miblen[i], &v, &l, NULL, 0) == 0) {
			jb_pf(j, "%s\"%s\":%d", first ? "" : ",", temp_names[i], v);
			first = 0;
		}
	}
	struct vmst v;
	if (vm_stats(&v) == 0)
		jb_pf(j, "},\"vm\":{\"free\":%llu,\"active\":%llu,\"inactive\":%llu,\"wired\":%llu,\"compressed\":%llu,\"spec\":%llu,"
		    "\"pageins\":%llu,\"swapins\":%llu,\"faults\":%llu,\"page_kb\":%u}", (unsigned long long)v.free,
		    (unsigned long long)v.active, (unsigned long long)v.inactive, (unsigned long long)v.wired,
		    (unsigned long long)v.compressed, (unsigned long long)v.spec, (unsigned long long)(v.pageins - sp.vm.pageins),
		    (unsigned long long)(v.swapins - sp.vm.swapins), (unsigned long long)(v.faults - sp.vm.faults), v.page_kb);
	else
		jb_pf(j, "}");
	sp.vm = v;
	double la[3] = { 0, 0, 0 };
	getloadavg(la, 3);
	jb_pf(j, ",\"load\":[%.2f,%.2f,%.2f]", la[0], la[1], la[2]);
	if (topevery == 0 || sp.n % topevery == 0)
		proc_table(j, 1);
	uint64_t su = self_cpu_us();
	jb_pf(j, ",\"self\":{\"cpu_ms\":%.1f,\"rss_kb\":%llu,\"klog_bps\":%.0f,\"tx_bps\":%.0f,\"dropped\":%llu,\"queued\":%zu}",
	    (double)(su - sp.self_us) / 1000, (unsigned long long)self_rss_kb(), (double)(k_bytes - sp.kbytes) / ds,
	    (double)(tx_bytes - sp.tx) / ds, (unsigned long long)dropped_frames, cl ? cl->queued : 0);
	if (kl.on && kl.total_t_ms)
		jb_pf(j, ",\"klog_bps\":%.0f,\"klog_total\":%llu", (double)(kl.total - sp.ktotal) / ds, (unsigned long long)kl.total);
	else
		jb_pf(j, ",\"klog_bps\":null");
	jb_pf(j, "}");
	sp.self_us = su;
	sp.tx = tx_bytes;
	sp.kbytes = k_bytes;
	sp.ktotal = kl.total;
	kl.total_t_ms = 1;
	sp.abs = now;
	sp.n++;
	send_json(cl, 'S', j, 1);
}

/* ------------------------------------------------------------------------------------------------ frames mode */

static struct { int on, paused, owned; kd_buf *buf; size_t cap; uint64_t last_abs; } fm;
static const char *kd_owner = "none";   /* none | trace | frames */

static int frames_start(char *err, size_t errn)
{
	if (kd(KERN_KDREMOVE, 0, NULL, NULL) < 0) {
		snprintf(err, errn, "KERN_KDREMOVE: %s (EBUSY: another ktrace owner, sweettrace -R)", strerror(errno));
		return -1;
	}
	static uint8_t tf[TYPEFILTER_SIZE];
	memset(tf, 0, sizeof(tf));
	tf_allow(tf, DBG_DRIVERS, SWEET_SUBCLASS);
	size_t tl = sizeof(tf);
	if (kd(KERN_KDSETBUF, 65536, NULL, NULL) < 0 || kd(KERN_KDSETUP, 0, NULL, NULL) < 0 ||
	    kd(KERN_KDSET_TYPEFILTER, 0, tf, &tl) < 0 || kd(KERN_KDENABLE, KDEBUG_ENABLE_TRACE, NULL, NULL) < 0) {
		snprintf(err, errn, "kdebug setup: %s", strerror(errno));
		kd(KERN_KDREMOVE, 0, NULL, NULL);
		return -1;
	}
	if (fm.buf == NULL) {
		fm.cap = 16384;
		fm.buf = malloc(fm.cap * sizeof(kd_buf));
	}
	fm.owned = 1;
	fm.last_abs = abs_now();
	kd_owner = "frames";
	return 0;
}

static void frames_release(void)
{
	if (fm.owned) {
		kd(KERN_KDENABLE, 0, NULL, NULL);
		kd(KERN_KDREMOVE, 0, NULL, NULL);
		fm.owned = 0;
		kd_owner = "none";
	}
}

static int dcmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}
static double pct(double *v, size_t n, double p)
{
	if (n == 0)
		return -1;
	qsort(v, n, sizeof(*v), dcmp);
	size_t i = (size_t)(p * (double)(n - 1) + 0.5);
	return v[i < n ? i : n - 1];
}

#define FM_MAXV 4096
static double fm_gpu[FM_MAXV], fm_lat[FM_MAXV];
static void frames_read(void)
{
	if (!fm.owned || fm.buf == NULL)
		return;
	uint64_t frames = 0, vsync = 0;
	size_t ng = 0, nl = 0;
	for (int round = 0; round < 16; round++) {
		size_t len = fm.cap * sizeof(kd_buf);
		if (kd(KERN_KDREADTR, 0, fm.buf, &len) < 0)
			break;
		for (size_t i = 0; i < len; i++) {
			const kd_buf *e = &fm.buf[i];
			if ((e->debugid & 0xffff0000u) != SWT_SW_BASE)
				continue;
			unsigned code = (e->debugid >> 2) & 0x3fff;
			if (code == 0x07) {             /* SHOWN: a1 = swap time (abs) */
				frames++;
				if (nl < FM_MAXV && e->arg1 && e->timestamp > e->arg1)
					fm_lat[nl++] = ticks_ms(e->timestamp - e->arg1);
			} else if (code == 0x01) {      /* VSYNC */
				vsync++;
			} else if (code == 0x11 && ng < FM_MAXV && e->arg3 > e->arg2) {   /* GPU_DONE: 19.2 MHz stamps */
				fm_gpu[ng++] = (double)(e->arg3 - e->arg2) / 19200.0;
			}
		}
		if (len < fm.cap)
			break;
	}
	kbufinfo_t bi;
	int wrapped = kd_info(&bi) == 0 && (bi.flags & KDBG_WRAPPED);
	uint64_t now = abs_now();
	double dt = ticks_ms(now - fm.last_abs) / 1000;
	fm.last_abs = now;
	struct jb *j = &sj;
	j->n = 0;
	jb_pf(j, "{\"t\":%llu,\"frames\":%llu,\"fps\":%.1f,\"vsync\":%llu,\"gpu_n\":%zu,\"gpu_ms_p50\":%.2f,\"gpu_ms_p90\":%.2f,"
	    "\"present_to_shown_ms_p50\":%.2f,\"wrapped\":%s}", (unsigned long long)abs_to_ns(now), (unsigned long long)frames,
	    dt > 0 ? (double)frames / dt : 0.0, (unsigned long long)vsync, ng, pct(fm_gpu, ng, 0.5), pct(fm_gpu, ng, 0.9),
	    pct(fm_lat, nl, 0.5), wrapped ? "true" : "false");
	send_json(cl, 'F', j, 1);
}

/* ------------------------------------------------------------------------------------------------ worker (trace, pmem) */

enum { J_IDLE, J_RUN, J_DONE, J_SEND };
static struct job {
	int state, kind;                /* kind 1 kdebug, 2 pmem */
	uint32_t id, seq;
	pthread_t th;
	atomic_int stop, cancel;
	/* options */
	unsigned secs, kbufs, quiet, read_ms;
	uint64_t maxev, pa, plen;
	int sysc, nointr;
	char focus[256], classes[256], args[128];
	/* results */
	int started, failed;
	char err[200];
	struct zout z;
	size_t zoff;
	uint64_t raw, events;
	uint32_t threads;
	int wrapped;
	uint64_t lost;
	double secs_done, cpu_ms;
	int reply_pending;              /* trace start: R after the setup */
} job;
static uint32_t next_id = 1;

static void wnote(char c)
{
	ssize_t r = write(wpipe[1], &c, 1);
	(void)r;
}

static double thread_cpu_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
	return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static kd_buf *ev, *chunk;
static uint64_t nev, capev, dropped_ev;
static size_t chunk_n;

static int drain(void)
{
	for (int round = 0; round < 64; round++) {
		size_t len = chunk_n * sizeof(kd_buf);
		if (kd(KERN_KDREADTR, 0, chunk, &len) < 0)
			return -1;
		size_t got = len;
		if (got == 0)
			return 0;
		size_t read_n = got;
		if (job.focus[0])
			got = swt_prefilter(chunk, got);
		uint64_t keep = got;
		if (nev + keep > job.maxev) {
			keep = job.maxev > nev ? job.maxev - nev : 0;
			dropped_ev += got - keep;
		}
		if (nev + keep > capev) {
			uint64_t c = capev ? capev : 262144;
			while (c < nev + keep)
				c *= 2;
			if (c > job.maxev)
				c = job.maxev;
			kd_buf *n = realloc(ev, c * sizeof(kd_buf));
			if (n == NULL) {
				dropped_ev += keep;
				keep = 0;
			} else {
				ev = n;
				capev = c;
			}
		}
		memcpy(ev + nev, chunk, keep * sizeof(kd_buf));
		nev += keep;
		if (read_n < chunk_n)
			return 0;
	}
	return 0;
}

static void trace_free(void)
{
	free(ev);
	free(chunk);
	free(thr);
	ev = chunk = NULL;
	thr = NULL;
	nev = capev = dropped_ev = 0;
	nthr = capthr = 0;
}

static void sleep_ms_stop(unsigned ms)
{
	while (ms > 0 && !atomic_load(&job.stop) && !atomic_load(&job.cancel)) {
		unsigned m = ms < 20 ? ms : 20;
		struct timespec ts = { 0, (long)m * 1000000L };
		nanosleep(&ts, NULL);
		ms -= m;
	}
}

static void *kdebug_worker(void *arg)
{
	(void)arg;
	unsigned kbufs = job.kbufs;
	kbufinfo_t bi;
	memset(&bi, 0, sizeof(bi));
	if (kd(KERN_KDREMOVE, 0, NULL, NULL) < 0) {
		snprintf(job.err, sizeof(job.err), "KERN_KDREMOVE: %s (root needed; EBUSY: another ktrace owner)", strerror(errno));
		goto fail;
	}
	for (;;) {
		if (kd(KERN_KDSETBUF, (int)kbufs, NULL, NULL) < 0) {
			snprintf(job.err, sizeof(job.err), "KERN_KDSETBUF: %s", strerror(errno));
			goto fail;
		}
		if (kd(KERN_KDSETUP, 0, NULL, NULL) == 0)
			break;
		if (kbufs <= 65536) {
			snprintf(job.err, sizeof(job.err), "KERN_KDSETUP: %s", strerror(errno));
			goto fail;
		}
		kbufs /= 2;
	}
	if (kd_info(&bi) == 0 && bi.nkdbufs > 0)
		kbufs = (unsigned)bi.nkdbufs;
	{
		static uint8_t tf[TYPEFILTER_SIZE];
		memset(tf, 0, sizeof(tf));
		memset(swt_whole, 0, sizeof(swt_whole));
		tf_allow(tf, DBG_TRACE, -1);
		tf_allow(tf, DBG_MACH, DBG_MACH_SCHED);
		tf_allow(tf, DBG_MACH, DBG_MACH_IPC);
		if (!job.nointr)
			tf_allow(tf, DBG_MACH, DBG_MACH_EXCP_INTR);
		tf_allow(tf, DBG_DRIVERS, SWEET_SUBCLASS);
		if (job.sysc) {
			tf_allow(tf, DBG_MACH, DBG_MACH_EXCP_SC);
			tf_allow(tf, DBG_BSD, DBG_BSD_EXCP_SC);
			tf_allow(swt_whole, DBG_MACH, DBG_MACH_EXCP_SC);
			tf_allow(swt_whole, DBG_BSD, DBG_BSD_EXCP_SC);
		}
		if (job.classes[0]) {
			char *s = strdup(job.classes), *save = NULL;
			for (char *t = s ? strtok_r(s, ",", &save) : NULL; t; t = strtok_r(NULL, ",", &save)) {
				char *sl = strchr(t, '/');
				unsigned c = (unsigned)strtoul(t, NULL, 0);
				int sub = sl ? (int)strtoul(sl + 1, NULL, 0) : -1;
				if (c < 256 && sub < 256) {
					tf_allow(tf, c, sub);
					tf_allow(swt_whole, c, sub);
				}
			}
			free(s);
		}
		size_t tl = sizeof(tf);
		if (kd(KERN_KDSET_TYPEFILTER, 0, tf, &tl) < 0) {
			snprintf(job.err, sizeof(job.err), "KERN_KDSET_TYPEFILTER: %s", strerror(errno));
			goto fail;
		}
	}
	chunk_n = kbufs < 262144 ? kbufs : 262144;
	chunk = malloc(chunk_n * sizeof(kd_buf));
	if (chunk == NULL) {
		snprintf(job.err, sizeof(job.err), "malloc: %s", strerror(errno));
		goto fail;
	}
	map_names();
	struct timespec wall;
	clock_gettime(CLOCK_REALTIME, &wall);
	uint64_t t0 = mach_absolute_time();
	if (kd(KERN_KDENABLE, KDEBUG_ENABLE_TRACE, NULL, NULL) < 0) {
		snprintf(job.err, sizeof(job.err), "KERN_KDENABLE: %s", strerror(errno));
		goto fail;
	}
	if (kd_info(&bi) == 0 && bi.nkdthreads > 0) {
		size_t ml = (size_t)bi.nkdthreads * sizeof(kd_threadmap);
		kd_threadmap *m = malloc(ml);
		if (m != NULL && kd(KERN_KDTHRMAP, 0, m, &ml) == 0)
			map_kdebug(m, ml / sizeof(kd_threadmap));
		free(m);
	}
	job.started = 1;
	wnote('s');
	uint64_t dur = (uint64_t)job.secs * 1000000000ull * tb.denom / tb.numer;
	uint32_t reads = 0;
	while (!atomic_load(&job.stop) && !atomic_load(&job.cancel) && mach_absolute_time() - t0 < dur && dropped_ev == 0) {
		sleep_ms_stop(job.read_ms);
		if (drain() < 0)
			break;
		reads++;
	}
	kd(KERN_KDENABLE, 0, NULL, NULL);
	uint64_t t1 = mach_absolute_time();
	drain();
	kd_info(&bi);
	{
		size_t ml = 32768 * sizeof(kd_threadmap);
		kd_threadmap *m = malloc(ml);
		if (m != NULL && kd(KERN_KDREADCURTHRMAP, 0, m, &ml) == 0)
			map_kdebug(m, ml / sizeof(kd_threadmap));
		free(m);
	}
	kd(KERN_KDREMOVE, 0, NULL, NULL);
	if (atomic_load(&job.cancel))
		goto out;
	map_names();
	uint32_t nfocus = 0;
	if (job.focus[0])
		nev = swt_reduce(ev, nev, thr, nthr, job.focus, &nfocus);
	struct swt_header h;
	memset(&h, 0, sizeof(h));
	memcpy(h.magic, SWT_MAGIC, 8);
	h.version = 1;
	h.header_size = sizeof(h);
	h.tb_numer = tb.numer;
	h.tb_denom = tb.denom;
	h.start_abs = t0;
	h.end_abs = t1;
	h.n_events = nev;
	h.n_threads = nthr;
	h.ncpu = (uint32_t)ncpu_now();
	h.kd_flags = bi.flags;
	h.kbufs = kbufs;
	h.reads = reads;
	h.dropped = (uint32_t)dropped_ev;
	h.tracer_pid = getpid();
	h.read_ms = job.read_ms;
	h.start_wall_ns = (uint64_t)wall.tv_sec * 1000000000ull + (uint64_t)wall.tv_nsec;
	memcpy(h.args, job.args, sizeof(h.args));
	h.args[sizeof(h.args) - 1] = 0;
	struct lzf z;
	if (lzf_begin(&z, &job.z, &job.cancel) < 0 || lzf_write(&z, &h, sizeof(h)) < 0 ||
	    (nev && lzf_write(&z, ev, nev * sizeof(kd_buf)) < 0) || (nthr && lzf_write(&z, thr, (size_t)nthr * sizeof(*thr)) < 0)) {
		lzf_end(&z);
		snprintf(job.err, sizeof(job.err), "compress: %s", job.z.err ? "out of memory" : "cancelled");
		job.failed = 1;
		goto out;
	}
	if (lzf_end(&z) < 0) {
		snprintf(job.err, sizeof(job.err), "compress: out of memory");
		job.failed = 1;
		goto out;
	}
	job.raw = z.raw;
	job.events = nev;
	job.threads = nthr;
	job.wrapped = (bi.flags & KDBG_WRAPPED) != 0;
	job.lost = dropped_ev;
	job.secs_done = ticks_ms(t1 - t0) / 1000;
out:
	job.cpu_ms = thread_cpu_ms();
	trace_free();
	wnote('d');
	return NULL;
fail:
	kd(KERN_KDREMOVE, 0, NULL, NULL);
	job.failed = 1;
	job.cpu_ms = thread_cpu_ms();
	trace_free();
	wnote('s');
	wnote('d');
	return NULL;
}

static void *pmem_worker(void *arg)
{
	(void)arg;
	uint64_t t0 = abs_now();
	uint8_t *b = malloc(1u << 20);
	struct lzf z;
	if (b == NULL || lzf_begin(&z, &job.z, &job.cancel) < 0) {
		snprintf(job.err, sizeof(job.err), "out of memory");
		job.failed = 1;
	} else {
		for (uint64_t off = 0; off < job.plen && !job.failed; off += 1u << 20) {
			size_t n = job.plen - off < (1u << 20) ? (size_t)(job.plen - off) : (1u << 20);
			if (atomic_load(&job.cancel) || pmem_read(job.pa + off, b, n) < 0 || lzf_write(&z, b, n) < 0) {
				snprintf(job.err, sizeof(job.err), "read 0x%llx: %s", (unsigned long long)(job.pa + off),
				    atomic_load(&job.cancel) ? "cancelled" : strerror(errno));
				job.failed = 1;
			}
		}
		if (lzf_end(&z) < 0 && !job.failed) {
			snprintf(job.err, sizeof(job.err), "compress: out of memory");
			job.failed = 1;
		}
		job.raw = z.raw;
	}
	free(b);
	job.secs_done = ticks_ms(abs_now() - t0) / 1000;
	job.cpu_ms = thread_cpu_ms();
	wnote('d');
	return NULL;
}

static void frames_resume(void)
{
	if (fm.on && !fm.owned && job.state == J_IDLE) {
		char err[160];
		if (frames_start(err, sizeof(err)) < 0) {
			dbg("frames resume: %s", err);
			fm.on = 0;
		}
	}
}

static void job_reset(void)
{
	free(job.z.p);
	memset(&job.z, 0, sizeof(job.z));
	job.state = J_IDLE;
	if (strcmp(kd_owner, "trace") == 0)
		kd_owner = "none";
	frames_resume();
}

/* cancel a running job (waits for the worker; it notices within ~20 ms or one compressed block) */
static void job_abort(void)
{
	if (job.state == J_RUN) {
		atomic_store(&job.cancel, 1);
		pthread_join(job.th, NULL);
		char c[16];
		while (read(wpipe[0], c, sizeof(c)) > 0) {
		}
		if (job.kind == 1)
			kd(KERN_KDREMOVE, 0, NULL, NULL);
	} else if (job.state == J_DONE) {
		pthread_join(job.th, NULL);
	}
	if (job.state != J_IDLE)
		job_reset();
}

static void job_end_frame(struct conn *c)
{
	struct jb *j = &sj;
	j->n = 0;
	jb_pf(j, "{\"id\":%u,\"kind\":\"%s\",\"bytes\":%llu,\"zbytes\":%zu,\"events\":%llu,\"threads\":%u,\"wrapped\":%s,"
	    "\"lost\":%llu,\"secs\":%.3f,\"cpu_ms\":%.1f", job.id, job.kind == 1 ? "kdebug" : "pmem", (unsigned long long)job.raw,
	    job.z.n, (unsigned long long)job.events, job.threads, job.wrapped ? "true" : "false", (unsigned long long)job.lost,
	    job.secs_done, job.cpu_ms);
	if (job.failed) {
		jb_pf(j, ",\"error\":");
		jb_str(j, job.err, sizeof(job.err));
	}
	jb_pf(j, "}");
	send_json(c, 'E', j, 0);
}

/* the worker said something (pipe) */
static void job_event(void)
{
	char c[16];
	ssize_t n = read(wpipe[0], c, sizeof(c));
	for (ssize_t i = 0; i < n; i++) {
		if (c[i] == 's' && job.reply_pending) {
			job.reply_pending = 0;
			char ex[64];
			snprintf(ex, sizeof(ex), ",\"id\":%u", job.id);
			if (job.failed)
				reply(cl, "trace", 0, ex, "%s", job.err);
			else
				reply(cl, "trace", 1, ex, "recording %u s", job.secs);
		} else if (c[i] == 'd' && job.state == J_RUN) {
			pthread_join(job.th, NULL);
			job.state = J_SEND;
			job.zoff = 0;
			if (job.kind == 1) {
				kd_owner = "none";
				frames_resume();
			}
			if (job.failed && job.kind == 1 && !job.started) {
				job_reset();    /* setup failed: the R said so, nothing to send */
			}
		}
	}
}

/* T chunks then E, while there is room */
static void job_pump(void)
{
	if (job.state != J_SEND || cl == NULL)
		return;
	while (cl->queued < Q_PRODUCE && job.zoff < job.z.n && !job.failed) {
		size_t m = job.z.n - job.zoff < T_CHUNK ? job.z.n - job.zoff : T_CHUNK;
		uint8_t hd[8];
		wr32(hd, job.id);
		wr32(hd + 4, job.seq++);
		send_frame(cl, 'T', hd, 8, job.z.p + job.zoff, m, 0);
		job.zoff += m;
	}
	if (job.failed || job.zoff >= job.z.n) {
		job_end_frame(cl);
		job_reset();
	}
}

/* ------------------------------------------------------------------------------------------------ speed */

static struct { uint64_t left, total; uint64_t t0, cpu0; int on; } spd;
static uint8_t *fill_buf;

static void speed_pump(void)
{
	if (!spd.on || cl == NULL)
		return;
	while (spd.left > 0 && cl->queued < Q_PRODUCE) {
		send_frame(cl, 'P', fill_buf, 1u << 20, NULL, 0, 0);
		spd.left--;
	}
	if (spd.left == 0 && cl->queued == 0) {
		char ex[160];
		double s = ticks_ms(abs_now() - spd.t0) / 1000;
		snprintf(ex, sizeof(ex), ",\"mb\":%llu,\"secs\":%.3f,\"mbps\":%.2f,\"cpu_ms\":%.1f", (unsigned long long)spd.total, s,
		    s > 0 ? (double)spd.total / s : 0.0, (double)(self_cpu_us() - spd.cpu0) / 1000);
		reply(cl, "speed", 1, ex, "sent");
		spd.on = 0;
	}
}

/* ------------------------------------------------------------------------------------------------ commands */

static void hello(struct conn *c)
{
	struct jb j = { 0, 0, 0 };
	struct timeval tv;
	gettimeofday(&tv, NULL);
	int64_t bt = boottime_s();
	jb_pf(&j, "{\"v\":1,\"pid\":%d,\"uptime_s\":%lld,\"ncpu\":%d,\"tb_numer\":%u,\"tb_denom\":%u,\"boottime\":%lld,\"ifaces\":{",
	    getpid(), (long long)(tv.tv_sec - bt), ncpu_now(), tb.numer, tb.denom, (long long)bt);
	struct ifaddrs *ifa = NULL, *i;
	int first = 1;
	if (getifaddrs(&ifa) == 0) {
		for (i = ifa; i != NULL; i = i->ifa_next) {
			if (i->ifa_addr == NULL || i->ifa_addr->sa_family != AF_INET || strcmp(i->ifa_name, "lo0") == 0 ||
			    strcmp(i->ifa_name, "lo") == 0)
				continue;
			char a[INET_ADDRSTRLEN];
			inet_ntop(AF_INET, &((struct sockaddr_in *)(void *)i->ifa_addr)->sin_addr, a, sizeof(a));
			jb_pf(&j, "%s", first ? "" : ",");
			jb_str(&j, i->ifa_name, 32);
			jb_pf(&j, ":\"%s\"", a);
			first = 0;
		}
		freeifaddrs(ifa);
	}
	if (kl.on)
		jb_pf(&j, "},\"klog_pa\":\"0x%llx\",\"version\":", (unsigned long long)kl.pa);
	else
		jb_pf(&j, "},\"klog_pa\":null,\"version\":");
	jb_str(&j, SWEETMON_VERSION, 64);
	jb_pf(&j, ",\"auth\":%s}", token ? "true" : "false");
	send_json(c, 'H', &j, 0);
	free(j.p);
}

static int tok_eq(const char *a, const char *b)
{
	size_t la = strlen(a), lb = strlen(b);
	unsigned d = la != lb;
	for (size_t i = 0; i < la && i < lb; i++)
		d |= (unsigned char)a[i] ^ (unsigned char)b[i];
	return d == 0;
}

static void conn_close(struct conn *c);

static void cmd_trace(struct conn *c, char **av, int ac)
{
	if (ac < 2) {
		reply(c, "trace", 0, NULL, "usage: trace start kdebug [k=v...] | trace stop | trace abort");
		return;
	}
	char ex[64];
	if (strcmp(av[1], "stop") == 0) {
		snprintf(ex, sizeof(ex), ",\"id\":%u", job.id);
		if (job.state == J_RUN && job.kind == 1) {
			atomic_store(&job.stop, 1);
			reply(c, "trace", 1, ex, "stopping");
		} else {
			reply(c, "trace", 0, ex, "no trace recording");
		}
		return;
	}
	if (strcmp(av[1], "abort") == 0) {
		snprintf(ex, sizeof(ex), ",\"id\":%u", job.id);
		int had = job.state != J_IDLE;
		if (job.reply_pending) {
			job.reply_pending = 0;
			reply(c, "trace", 0, ex, "aborted before start");
		}
		job_abort();
		reply(c, "trace", had, ex, had ? "aborted" : "no trace");
		return;
	}
	if (strcmp(av[1], "start") != 0 || ac < 3 || strcmp(av[2], "kdebug") != 0) {
		reply(c, "trace", 0, NULL, "only `trace start kdebug ...` (kernel profiler traces: poke + pmem)");
		return;
	}
	if (job.state != J_IDLE) {
		snprintf(ex, sizeof(ex), ",\"id\":%u", job.id);
		reply(c, "trace", 0, ex, "busy: trace or pmem %u running", job.id);
		return;
	}
	unsigned secs = 60, quiet = 0, max_mb = 512, kbufs = 1u << 20;
	int sysc = 0, nointr = 0;
	const char *filter = "f", *classes = "";
	for (int i = 3; i < ac; i++) {
		char *eq = strchr(av[i], '=');
		if (eq == NULL) {
			reply(c, "trace", 0, NULL, "bad option %s", av[i]);
			return;
		}
		*eq = 0;
		const char *k = av[i], *v = eq + 1;
		if (strcmp(k, "secs") == 0)
			secs = (unsigned)strtoul(v, NULL, 0);
		else if (strcmp(k, "mode") == 0) {
			if (strcmp(v, "buffer") != 0) {
				reply(c, "trace", 0, NULL, "mode=%s: only mode=buffer in v1", v);
				return;
			}
		} else if (strcmp(k, "filter") == 0)
			filter = v;
		else if (strcmp(k, "classes") == 0)
			classes = v;
		else if (strcmp(k, "syscalls") == 0)
			sysc = atoi(v) != 0;
		else if (strcmp(k, "intr") == 0)
			nointr = atoi(v) == 0;
		else if (strcmp(k, "kbuf") == 0)
			kbufs = (unsigned)strtoul(v, NULL, 0);
		else if (strcmp(k, "max_mb") == 0)
			max_mb = (unsigned)strtoul(v, NULL, 0);
		else if (strcmp(k, "quiet") == 0)
			quiet = atoi(v) != 0;
		else {
			reply(c, "trace", 0, NULL, "unknown option %s", k);
			return;
		}
		*eq = '=';
	}
	if (secs == 0)
		secs = 60;
	if (secs > 600)
		secs = 600;
	if (max_mb < 1)
		max_mb = 1;
	if (kbufs < 65536)
		kbufs = 65536;
	frames_release();               /* frame mode (fm.on) resumes after the trace */
	free(job.z.p);
	memset(&job, 0, sizeof(job));
	job.kind = 1;
	job.id = next_id++;
	job.secs = secs;
	job.quiet = quiet;
	job.read_ms = 100;
	job.kbufs = kbufs;
	job.maxev = ((uint64_t)max_mb << 20) / sizeof(kd_buf);
	job.sysc = sysc;
	job.nointr = nointr;
	if (strcmp(filter, "f") == 0)
		snprintf(job.focus, sizeof(job.focus), "backboardd,SpringBoard,Preferences");
	else if (strcmp(filter, "none") != 0)
		snprintf(job.focus, sizeof(job.focus), "%s", filter);
	snprintf(job.classes, sizeof(job.classes), "%s", classes);
	{
		size_t w = (size_t)snprintf(job.args, sizeof(job.args), "sweetmon");
		for (int i = 3; i < ac && w < sizeof(job.args) - 1; i++)
			w += (size_t)snprintf(job.args + w, sizeof(job.args) - w, " %s", av[i]);
	}
	job.reply_pending = 1;
	job.state = J_RUN;
	kd_owner = "trace";
	if (pthread_create(&job.th, NULL, kdebug_worker, NULL) != 0) {
		job.state = J_IDLE;
		job.reply_pending = 0;
		kd_owner = "none";
		reply(c, "trace", 0, NULL, "pthread_create: %s", strerror(errno));
		frames_resume();
	}
	dbg("trace %u start: secs %u focus '%s' classes '%s' sysc %d nointr %d kbuf %u max_mb %u quiet %u", job.id, secs,
	    job.focus, classes, sysc, nointr, kbufs, max_mb, quiet);
}

static void cmd_pmem(struct conn *c, char **av, int ac)
{
	if (ac < 3) {
		reply(c, "pmem", 0, NULL, "usage: pmem PA LEN [id]");
		return;
	}
	if (job.state != J_IDLE) {
		reply(c, "pmem", 0, NULL, "busy: trace or pmem %u running", job.id);
		return;
	}
	uint64_t pa = strtoull(av[1], NULL, 0), len = strtoull(av[2], NULL, 0);
	if (len == 0 || len > (64ull << 20)) {
		reply(c, "pmem", 0, NULL, "LEN must be 1..64 MiB");
		return;
	}
	if (pmem_open() < 0) {
		reply(c, "pmem", 0, NULL, "%s: %s (boot-arg sweetpmem=1?)", pmem_dev, strerror(errno));
		return;
	}
	free(job.z.p);
	memset(&job, 0, sizeof(job));
	job.kind = 2;
	job.id = ac > 3 ? (uint32_t)strtoul(av[3], NULL, 0) : next_id++;
	job.pa = pa;
	job.plen = len;
	job.state = J_RUN;
	char ex[64];
	snprintf(ex, sizeof(ex), ",\"id\":%u", job.id);
	if (pthread_create(&job.th, NULL, pmem_worker, NULL) != 0) {
		job.state = J_IDLE;
		reply(c, "pmem", 0, ex, "pthread_create: %s", strerror(errno));
		return;
	}
	reply(c, "pmem", 1, ex, "reading %llu bytes at 0x%llx", (unsigned long long)len, (unsigned long long)pa);
}

static void cmd_klog(struct conn *c, char **av, int ac)
{
	char ex[128];
	if (ac < 2) {
		reply(c, "klog", 0, NULL, "usage: klog PA | klog off | klog from POS");
		return;
	}
	if (strcmp(av[1], "off") == 0) {
		kl.on = 0;
		reply(c, "klog", 1, NULL, "off");
		return;
	}
	if (strcmp(av[1], "from") == 0) {
		if (!kl.on || ac < 3) {
			reply(c, "klog", 0, NULL, kl.on ? "usage: klog from POS" : "klog is off");
			return;
		}
		uint64_t p = strtoull(av[2], NULL, 0);
		klog_poll();
		snprintf(ex, sizeof(ex), ",\"pos\":%llu,\"total\":%llu", (unsigned long long)p, (unsigned long long)kl.total);
		if (p > kl.total || kl.total - p > KLOG_RING) {
			reply(c, "klog", 0, ex, p > kl.total ? "POS is past the ring total" : "POS is no longer in the ring");
			return;
		}
		kl.pos = p;
		reply(c, "klog", 1, ex, "resending");
		return;
	}
	uint64_t pa = strtoull(av[1], NULL, 0);
	if (pa == 0) {
		reply(c, "klog", 0, NULL, "bad PA %s", av[1]);
		return;
	}
	if (pmem_open() < 0) {
		reply(c, "klog", 0, NULL, "%s: %s (boot-arg sweetpmem=1?)", pmem_dev, strerror(errno));
		return;
	}
	uint64_t save_pa = kl.pa, total = 0;
	kl.pa = pa;
	if (klog_total(&total) < 0) {
		kl.pa = save_pa;
		reply(c, "klog", 0, NULL, "read 0x%llx: %s", (unsigned long long)pa, strerror(errno));
		return;
	}
	snprintf(ex, sizeof(ex), ",\"pa\":\"0x%llx\",\"total\":%llu", (unsigned long long)pa, (unsigned long long)total);
	if (total > (1ull << 40) || total == 0) {
		kl.pa = save_pa;
		reply(c, "klog", 0, ex, total ? "total > 2^40: not the log ring (wrong PA for this kernel?)" : "total is 0: empty ring or wrong PA");
		return;
	}
	uint8_t tail[4096];
	size_t n = total < sizeof(tail) ? (size_t)total : sizeof(tail), good = 0;
	if (ring_read(total - n, tail, n) < 0) {
		kl.pa = save_pa;
		reply(c, "klog", 0, ex, "ring read: %s", strerror(errno));
		return;
	}
	for (size_t i = 0; i < n; i++)
		good += (tail[i] >= 0x20 && tail[i] < 0x7f) || tail[i] == '\n' || tail[i] == '\t' || tail[i] == '\r' || tail[i] >= 0x80;
	if (good * 10 < n * 9) {
		kl.pa = save_pa;
		reply(c, "klog", 0, ex, "the last %zu bytes are not text (%zu printable): wrong PA?", n, good);
		return;
	}
	kl.on = 1;
	kl.total = total;
	kl.pos = total > KLOG_RING ? total - KLOG_RING : 0;
	kl.next_ms = now_ms() + KLOG_POLL_MS;
	sp.ktotal = total;
	kl.total_t_ms = 0;
	snprintf(ex, sizeof(ex), ",\"pa\":\"0x%llx\",\"total\":%llu,\"pos\":%llu", (unsigned long long)pa,
	    (unsigned long long)total, (unsigned long long)kl.pos);
	reply(c, "klog", 1, ex, "tailing");
}

static void cmd_info(struct conn *c)
{
	struct jb j = { 0, 0, 0 };
	kbufinfo_t bi;
	int kr = kd_info(&bi);
	jb_pf(&j, ",\"version\":");
	jb_str(&j, SWEETMON_VERSION, 64);
	jb_pf(&j, ",\"pid\":%d,\"daemon_s\":%.0f,\"rate_ms\":%u,\"topevery\":%u,\"top\":%u,\"auth\":%s,"
	    "\"klog\":{\"on\":%s,\"pa\":\"0x%llx\",\"pos\":%llu,\"total\":%llu},\"frames\":%s,\"kdebug_owner\":\"%s\",",
	    getpid(), ticks_ms(abs_now() - t_start_abs) / 1000, rate_ms, topevery, topn, token ? "true" : "false",
	    kl.on ? "true" : "false", (unsigned long long)kl.pa, (unsigned long long)kl.pos, (unsigned long long)kl.total,
	    fm.on ? "true" : "false", kd_owner);
	if (kr == 0)
		jb_pf(&j, "\"kdebug\":{\"nkdbufs\":%d,\"nolog\":%d,\"flags\":\"0x%x\",\"nkdthreads\":%d,\"bufid\":%d},", bi.nkdbufs,
		    bi.nolog, bi.flags, bi.nkdthreads, bi.bufid);
	else
		jb_pf(&j, "\"kdebug\":null,");
	static const char *js[] = { "idle", "recording", "done", "sending" };
	jb_pf(&j, "\"job\":{\"state\":\"%s\",\"id\":%u,\"kind\":%d,\"zbytes\":%zu},\"rss_kb\":%llu,\"cpu_ms_total\":%.0f,"
	    "\"queued\":%zu,\"tx_bytes\":%llu,\"dropped\":%llu", js[job.state], job.id, job.kind, job.z.n,
	    (unsigned long long)self_rss_kb(), (double)self_cpu_us() / 1000, c->queued, (unsigned long long)tx_bytes,
	    (unsigned long long)dropped_frames);
	reply(c, "info", 1, j.p, "sweetmon");
	free(j.p);
}

static void activate(struct conn *c)
{
	if (cl != NULL && cl != c)
		conn_close(cl);
	c->authed = 1;
	cl = c;
	sample_base();
	sp.n = 0;
	temps_resolve();
	next_sample_ms = now_ms() + rate_ms;
	dbg("client %s active", c->peer);
}

static void command(struct conn *c, char *line)
{
	char *av[24];
	int ac = 0;
	char *save = NULL;
	for (char *t = strtok_r(line, " \t\r\n", &save); t && ac < 24; t = strtok_r(NULL, " \t\r\n", &save))
		av[ac++] = t;
	if (ac == 0) {
		reply(c, "", 0, NULL, "empty command");
		return;
	}
	const char *cmd = av[0];
	if (strcmp(cmd, "auth") == 0) {
		if (token == NULL || (ac > 1 && tok_eq(av[1], token))) {
			reply(c, "auth", 1, NULL, "ok");
			if (cl != c)
				activate(c);
		} else {
			reply(c, "auth", 0, NULL, "bad token");
			if (++c->bad >= 3)
				c->dead = 1;
		}
		return;
	}
	if (!c->authed) {
		reply(c, cmd, 0, NULL, "auth required");
		return;
	}
	if (strcmp(cmd, "rate") == 0) {
		if (ac > 1) {
			unsigned v = (unsigned)strtoul(av[1], NULL, 0);
			rate_ms = v < 200 ? 200 : v > 10000 ? 10000 : v;
		}
		if (ac > 2)
			topevery = (unsigned)strtoul(av[2], NULL, 0);
		next_sample_ms = now_ms() + rate_ms;
		char ex[64];
		snprintf(ex, sizeof(ex), ",\"rate_ms\":%u,\"topevery\":%u", rate_ms, topevery);
		reply(c, cmd, 1, ex, "ok");
	} else if (strcmp(cmd, "top") == 0) {
		if (ac > 1)
			topn = (unsigned)strtoul(av[1], NULL, 0);
		char ex[32];
		snprintf(ex, sizeof(ex), ",\"top\":%u", topn);
		reply(c, cmd, 1, ex, "ok");
	} else if (strcmp(cmd, "klog") == 0) {
		cmd_klog(c, av, ac);
	} else if (strcmp(cmd, "trace") == 0) {
		cmd_trace(c, av, ac);
	} else if (strcmp(cmd, "pmem") == 0) {
		cmd_pmem(c, av, ac);
	} else if (strcmp(cmd, "frames") == 0) {
		if (ac > 1 && strcmp(av[1], "on") == 0) {
			char err[160] = "";
			if (fm.on) {
				reply(c, cmd, 1, NULL, "already on");
			} else if (job.state == J_RUN && job.kind == 1) {
				fm.on = 1;
				reply(c, cmd, 1, NULL, "on after the trace");
			} else if (frames_start(err, sizeof(err)) == 0) {
				fm.on = 1;
				reply(c, cmd, 1, NULL, "on");
			} else {
				reply(c, cmd, 0, NULL, "%s", err);
			}
		} else if (ac > 1 && strcmp(av[1], "off") == 0) {
			fm.on = 0;
			frames_release();
			reply(c, cmd, 1, NULL, "off");
		} else {
			reply(c, cmd, 0, NULL, "usage: frames on|off");
		}
	} else if (strcmp(cmd, "speed") == 0) {
		uint64_t mb = ac > 1 ? strtoull(av[1], NULL, 0) : 16;
		if (mb == 0 || mb > 1024 || spd.on) {
			reply(c, cmd, 0, NULL, spd.on ? "speed test running" : "MB must be 1..1024");
			return;
		}
		if (fill_buf == NULL) {
			fill_buf = malloc(1u << 20);
			if (fill_buf == NULL) {
				reply(c, cmd, 0, NULL, "out of memory");
				return;
			}
			uint64_t x = 0x9E3779B97F4A7C15ull ^ (uint64_t)getpid();
			for (size_t i = 0; i < (1u << 20); i += 8) {
				x ^= x << 13;
				x ^= x >> 7;
				x ^= x << 17;
				memcpy(fill_buf + i, &x, 8);
			}
		}
		spd.on = 1;
		spd.left = spd.total = mb;
		spd.t0 = abs_now();
		spd.cpu0 = self_cpu_us();
		speed_pump();
	} else if (strcmp(cmd, "ping") == 0) {
		reply(c, cmd, 1, NULL, "%s", ac > 1 ? av[1] : "");
	} else if (strcmp(cmd, "info") == 0) {
		cmd_info(c);
	} else if (strcmp(cmd, "quit") == 0) {
		reply(c, cmd, 1, NULL, "bye");
		quit_req = 1;
	} else {
		reply(c, cmd, 0, NULL, "unknown command");
	}
}

/* ------------------------------------------------------------------------------------------------ main loop */

static void conn_close(struct conn *c)
{
	if (c->fd < 0)
		return;
	dbg("close %s%s", c->peer, c == cl ? " (active)" : "");
	close(c->fd);
	c->fd = -1;
	while (c->qh != NULL) {
		struct qbuf *q = c->qh;
		c->qh = q->next;
		free(q);
	}
	c->qt = NULL;
	c->queued = 0;
	if (c == cl) {
		cl = NULL;
		fm.on = 0;              /* before job_abort: no frame-mode resume */
		job_abort();            /* a trace without its client: abort and free */
		job.reply_pending = 0;
		fm.on = 0;
		frames_release();
		kl.on = 0;
		spd.on = 0;
		free(kbuf);
		kbuf = NULL;
	}
}

static void conn_read(struct conn *c)
{
	ssize_t r = read(c->fd, c->rx + c->rxn, sizeof(c->rx) - c->rxn);
	if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR)) {
		c->dead = 1;
		return;
	}
	if (r < 0)
		return;
	c->rxn += (size_t)r;
	while (c->rxn >= 5 && !c->dead) {
		uint32_t len = rd32(c->rx);
		if (len < 1 || len > CMD_MAX) {
			c->dead = 1;
			return;
		}
		if (c->rxn < 4 + (size_t)len)
			break;
		char line[CMD_MAX + 1];
		uint8_t type = c->rx[4];
		memcpy(line, c->rx + 5, len - 1);
		line[len - 1] = 0;
		memmove(c->rx, c->rx + 4 + len, c->rxn - 4 - len);
		c->rxn -= 4 + len;
		if (type == 'C') {
			dbg("cmd from %s: %.80s", c->peer, line);
			command(c, line);
		}
	}
}

static void on_signal(int s)
{
	(void)s;
	sig_stop = 1;
	char b = 1;
	ssize_t r = write(sigpipe_fd[1], &b, 1);
	(void)r;
}

static int set_nb(int fd)
{
	int f = fcntl(fd, F_GETFL);
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	return fcntl(fd, F_SETFL, f | O_NONBLOCK);
}

static int lz4_file(const char *in, const char *out)
{
	FILE *f = fopen(in, "rb");
	if (f == NULL)
		return perror(in), 1;
	struct zout o = { 0, 0, 0, 0 };
	struct lzf z;
	static uint8_t b[1 << 16];
	size_t n;
	if (lzf_begin(&z, &o, NULL) < 0)
		return 1;
	while ((n = fread(b, 1, sizeof(b), f)) > 0)
		lzf_write(&z, b, n);
	fclose(f);
	if (lzf_end(&z) < 0)
		return fprintf(stderr, "lz4: out of memory\n"), 1;
	FILE *w = fopen(out, "wb");
	if (w == NULL || fwrite(o.p, 1, o.n, w) != o.n || fclose(w) != 0)
		return perror(out), 1;
	printf("%llu -> %zu bytes\n", (unsigned long long)z.raw, o.n);
	free(o.p);
	return 0;
}

static void daemonize(void)
{
	pid_t p = fork();
	if (p < 0)
		exit(1);
	if (p > 0)
		_exit(0);
	setsid();
	p = fork();
	if (p < 0)
		exit(1);
	if (p > 0)
		_exit(0);
	if (chdir("/") < 0) {
	}
	int fd = open("/dev/null", O_RDWR);
	if (fd >= 0) {
		dup2(fd, 0);
		dup2(fd, 1);
		dup2(fd, 2);
		if (fd > 2)
			close(fd);
	}
	daemonized = 1;
}

static char keybuf[256];
static const char *read_key(void)
{
	FILE *f = fopen(KEYFILE, "r");
	if (f == NULL)
		return NULL;
	char *r = fgets(keybuf, sizeof(keybuf), f);
	fclose(f);
	if (r == NULL)
		return NULL;
	size_t n = strlen(keybuf);
	while (n > 0 && (keybuf[n - 1] == '\n' || keybuf[n - 1] == '\r' || keybuf[n - 1] == ' ' || keybuf[n - 1] == '\t'))
		keybuf[--n] = 0;
	return n ? keybuf : NULL;
}

int main(int argc, char **argv)
{
	int port = 5150, daemon_mode = 0, noauth = 0, o;
	const char *logpath = NULL;
	mach_timebase_info(&tb);
	while ((o = getopt(argc, argv, "Dp:k:Kl:vZ")) != -1) {
		switch (o) {
		case 'D': daemon_mode = 1; break;
		case 'p': port = atoi(optarg); break;
		case 'k': token = optarg; break;
		case 'K': noauth = 1; break;
		case 'l': logpath = optarg; break;
		case 'v': verbose = 1; break;
		case 'Z':
			if (optind + 2 > argc)
				return fprintf(stderr, "usage: sweetmon -Z IN OUT\n"), 2;
			return lz4_file(argv[optind], argv[optind + 1]);
		default:
			fprintf(stderr, "usage: sweetmon [-D] [-p PORT] [-k TOKEN | -K] [-l LOGFILE] [-v] | sweetmon -Z IN OUT\n");
			return 2;
		}
	}
#ifndef __APPLE__
	if (getenv("SWEETMON_PMEM") != NULL)
		pmem_dev = getenv("SWEETMON_PMEM");
#endif
	if (noauth)
		token = NULL;
	else if (token == NULL && (token = read_key()) == NULL) {
		fprintf(stderr, "sweetmon: no token: %s missing or empty (or use -k TOKEN, -K for tests)\n", KEYFILE);
		return 1;
	}
	int ls = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1;
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);
	sa.sin_addr.s_addr = htonl(INADDR_ANY);
	if (ls < 0 || setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0 ||
	    bind(ls, (struct sockaddr *)&sa, sizeof(sa)) < 0 || listen(ls, 4) < 0) {
		fprintf(stderr, "sweetmon: port %d: %s\n", port, strerror(errno));
		return 1;
	}
	set_nb(ls);
	if (daemon_mode)
		daemonize();
	if (logpath != NULL)
		logf = fopen(logpath, "a");
	if (nice(10) == -1 && errno != 0)
		dbg("nice: %s", strerror(errno));
	signal(SIGPIPE, SIG_IGN);
	if (pipe(sigpipe_fd) < 0 || pipe(wpipe) < 0)
		return 1;
	set_nb(sigpipe_fd[0]);
	set_nb(sigpipe_fd[1]);
	set_nb(wpipe[0]);
	set_nb(wpipe[1]);
	struct sigaction act;
	memset(&act, 0, sizeof(act));
	act.sa_handler = on_signal;
	sigaction(SIGTERM, &act, NULL);
	sigaction(SIGINT, &act, NULL);
	sigaction(SIGHUP, &act, NULL);
	plat_init();
	t_start_abs = abs_now();
	sample_base();
	for (int i = 0; i < NCONN; i++)
		conns[i].fd = -1;
	dbg("sweetmon %s pid %d port %d auth %s", SWEETMON_VERSION, getpid(), port, token ? "on" : "off");
	uint64_t quit_ms = 0;

	while (!sig_stop) {
		/* close the dead, time out the unauthenticated */
		uint64_t now = now_ms();
		for (int i = 0; i < NCONN; i++) {
			struct conn *c = &conns[i];
			if (c->fd >= 0 && (c->dead || (!c->authed && now - c->since_ms > PEND_TIMEOUT_MS)))
				conn_close(c);
		}
		if (quit_req) {
			if (quit_ms == 0)
				quit_ms = now + 1000;
			if (cl == NULL || cl->queued == 0 || now > quit_ms)
				break;
		}
		int active = cl != NULL && cl->authed;
		int quiet = job.state == J_RUN && job.quiet;
		if (active) {
			if (now >= next_sample_ms) {
				if (!quiet) {
					sample();
					if (fm.owned)
						frames_read();
				}
				next_sample_ms += rate_ms;
				if (next_sample_ms <= now)
					next_sample_ms = now + rate_ms;
			}
			if (kl.on && now >= kl.next_ms) {
				if (!quiet)
					klog_poll();
				kl.next_ms = now + KLOG_POLL_MS;
			}
			job_pump();
			speed_pump();
			if (!quiet)
				klog_pump();
		}
		/* poll */
		struct pollfd pf[3 + NCONN];
		struct conn *pc[3 + NCONN];
		int np = 0;
		pf[np].fd = ls; pf[np].events = POLLIN; pc[np++] = NULL;
		pf[np].fd = sigpipe_fd[0]; pf[np].events = POLLIN; pc[np++] = NULL;
		pf[np].fd = wpipe[0]; pf[np].events = POLLIN; pc[np++] = NULL;
		int pending = 0;
		for (int i = 0; i < NCONN; i++) {
			struct conn *c = &conns[i];
			if (c->fd < 0)
				continue;
			pending |= !c->authed;
			pf[np].fd = c->fd;
			pf[np].events = (short)(POLLIN | (c->qh != NULL ? POLLOUT : 0));
			pc[np++] = c;
		}
		int timeout = -1;
		now = now_ms();
		if (active) {
			uint64_t next = next_sample_ms;
			if (kl.on && kl.next_ms < next)
				next = kl.next_ms;
			timeout = next > now ? (int)(next - now) : 0;
		}
		if (pending && (timeout < 0 || timeout > 1000))
			timeout = 1000;
		if (quit_req)
			timeout = 50;
		int r = poll(pf, (nfds_t)np, timeout);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (pf[2].revents & POLLIN)
			job_event();
		if (pf[0].revents & POLLIN) {
			struct sockaddr_in ca;
			socklen_t cal = sizeof(ca);
			int fd = accept(ls, (struct sockaddr *)&ca, &cal);
			if (fd >= 0) {
				struct conn *slot = NULL;
				for (int i = 0; i < NCONN && slot == NULL; i++)
					if (conns[i].fd < 0)
						slot = &conns[i];
				for (int i = 0; i < NCONN && slot == NULL; i++)   /* full: drop the oldest pending one */
					if (&conns[i] != cl && !conns[i].authed) {
						conn_close(&conns[i]);
						slot = &conns[i];
					}
				if (slot == NULL) {
					close(fd);
				} else {
					set_nb(fd);
					setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
					setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
					int sb = 1 << 20;
					setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sb, sizeof(sb));
					memset(slot, 0, sizeof(*slot));
					slot->fd = fd;
					slot->since_ms = now_ms();
					char a[INET_ADDRSTRLEN] = "?";
					inet_ntop(AF_INET, &ca.sin_addr, a, sizeof(a));
					snprintf(slot->peer, sizeof(slot->peer), "%s:%u", a, ntohs(ca.sin_port));
					dbg("accept %s", slot->peer);
					hello(slot);
					if (token == NULL)
						activate(slot);
				}
			}
		}
		for (int i = 3; i < np; i++) {
			struct conn *c = pc[i];
			if (c->fd < 0 || c->fd != pf[i].fd)
				continue;
			if ((pf[i].revents & (POLLERR | POLLHUP | POLLNVAL)) && !(pf[i].revents & POLLIN))
				c->dead = 1;
			if (pf[i].revents & POLLOUT)
				conn_flush(c);
			if (pf[i].revents & POLLIN)
				conn_read(c);
		}
	}
	dbg("exit (%s)", sig_stop ? "signal" : quit_req ? "quit" : "poll error");
	job_abort();
	frames_release();
	if (strcmp(kd_owner, "none") != 0)
		kd(KERN_KDREMOVE, 0, NULL, NULL);
	for (int i = 0; i < NCONN; i++)
		if (conns[i].fd >= 0)
			conn_close(&conns[i]);
	close(ls);
	return 0;
}
