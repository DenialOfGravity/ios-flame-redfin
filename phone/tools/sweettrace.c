/*
 * sweettrace: record a kdebug trace for the frame-pacing analysis (tools-claude/sweet-trace.py).
 *
 *   sweettrace [-t SECS] [-o FILE] [-b KBUFS] [-m MAXEVENTS] [-r MS] [-d DELAY] [-p PID,...] [-c CLASS[/SUB],...]
 *              [-S] [-I] [-n] [-f | -F PROC,...] [-z | -Z LEVEL]
 *
 *   -t SECS     how long to record (default 10)
 *   -o FILE     output (default /var/tmp/sweettrace.swtr)
 *   -b KBUFS    kernel buffer in events (default 1048576 = 64 MB; halved until the kernel takes it)
 *   -m MAX      keep at most MAX events in memory (default 4194304 = 256 MB; grown as needed)
 *   -r MS       read the kernel buffer every MS ms (default 100; 0 = only at the end, buffer set to not wrap)
 *   -d DELAY    wait DELAY seconds before starting
 *   -p PIDS     only events of these processes (kdebug's pid filter; 0 = the kernel). Default: everyone, since the
 *               waker of a thread is often in another process. Names work too: -p backboardd,Preferences,0
 *   -c CSC      also these classes (hex or decimal; CLASS = all its subclasses, CLASS/SUB = one), e.g. -c 0x31
 *   -S          also syscalls (BSD and Mach traps: many events)
 *   -I          no interrupts (DBG_MACH_EXCP_INTR)
 *   -n          no thread names (skip the proc_pidinfo walk)
 *   -F PROCS    u-lab: keep only what tools-claude/swtr-reduce.py keeps for these processes' frame chain (comma list of
 *               process names): all 0xF5 events, DBG_TRACE, interrupts, IPC kmsg info, MACH_IPC_MSG_SEND/RECV of their
 *               threads, wakes of their threads, context switches in/out of their threads; events in time order. The
 *               same events (byte for byte) as `swtr-reduce.py FULL OUT PROCS` on a full trace, 3-4x smaller. Events of
 *               -c / -S classes are kept whole. Events no rule can keep are dropped while reading (less memory).
 *   -f          -F backboardd,SpringBoard,Preferences (swtr-reduce.py's default)
 *   -z          gzip the output (zlib level 6; -Z LEVEL 1-9). The file is a plain gzip of the same format: `gzip -dc`
 *               on the PC gives the .swtr the PC tools read. A reduced Settings trace: ~180 MB full -> ~52 MB -f -> ~4.5 MB -f -z.
 *
 * Default classes: DBG_MACH/DBG_MACH_SCHED (context switches, MAKE_RUNNABLE with the waker as the current thread,
 * blocks, waits), DBG_MACH/DBG_MACH_IPC (mach_msg send/receive, KMSG_INFO sender -> receiver pid), DBG_MACH/
 * DBG_MACH_EXCP_INTR (interrupts), DBG_DRIVERS/0xF5 (0994's display/GPU/touch events), DBG_TRACE (always on).
 *
 * File (little endian): header (struct swt_header), n_events kd_buf (64 bytes each: timestamp, arg1-4, arg5 =
 * thread id, debugid, cpuid, unused), n_threads struct swt_thread (tid, pid, process name, thread name).
 *
 * Needs root (kdebug's ktrace_configure: superuser). Another owner of ktrace (EBUSY): `sweettrace -R` resets it.
 */
#include <errno.h>
#include <stddef.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifndef SWT_HOST_TEST
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <zlib.h>
#endif

/* bsd/sys/sysctl.h, bsd/sys/kdebug_private.h (not in the iOS SDK) */
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
#define KERN_KDPIDTR            11
#define KERN_KDTHRMAP           12
#define KERN_KDREADCURTHRMAP    21
#define KERN_KDSET_TYPEFILTER   22
#define KDEBUG_ENABLE_TRACE     0x1
#define KDBG_NOWRAP             0x0002
#define KDBG_WRAPPED            0x0008
#define KDBG_TYPENONE           0x80000
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

typedef struct {
	unsigned int type, value1, value2, value3, value4;
} kd_regtype;

/* libproc (no header in the iOS SDK) */
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
#define PROC_PIDTHREADID64INFO  15
#define PROC_PIDLISTTHREADIDS   28
struct proc_threadinfo {
	uint64_t pth_user_time, pth_system_time;
	int32_t pth_cpu_usage, pth_policy, pth_run_state, pth_flags, pth_sleep_time, pth_curpri, pth_priority,
	    pth_maxpriority;
	char pth_name[64];
};

#define SWT_MAGIC       "SWTRACE1"
struct swt_header {
	char     magic[8];
	uint32_t version, header_size;
	uint32_t tb_numer, tb_denom;    /* mach_timebase_info */
	uint64_t start_abs, end_abs;    /* tracing on / off (mach_absolute_time) */
	uint64_t n_events;
	uint32_t n_threads, ncpu;
	uint32_t kd_flags;              /* kbufinfo flags at the end (KDBG_WRAPPED: the kernel buffer overran) */
	uint32_t kbufs;                 /* kernel buffer size (events) */
	uint32_t reads, dropped;        /* periodic reads; events not kept (-m reached) */
	int32_t  tracer_pid;
	uint32_t read_ms;
	uint64_t start_wall_ns;         /* CLOCK_REALTIME at start */
	char     args[128];
};
struct swt_thread {
	uint64_t tid;
	int32_t  pid;
	uint32_t flags;                 /* 1 from the kdebug map, 2 from proc_pidinfo */
	char     comm[32];
	char     name[64];
};


/*
 * u-lab: -F, swtr-reduce.py on the phone. swt_prekeep() runs on every event read (drain): it drops what no rule below can
 * keep. swt_reduce() runs once at the end, on the time-sorted events and the final thread map, and applies the rules that
 * need the focus threads. Kept in step with tools-claude/swtr-reduce.py (the host test below checks byte equality).
 */
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

static uint8_t swt_whole[TYPEFILTER_SIZE];      /* -c / -S class-subclasses: kept whole under -F */

static int swt_always(uint32_t dbg)             /* kept whatever the focus */
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

/* keep the swt_prekeep() events of buf[0..n) in place; returns how many */
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
static int swt_idx_cmp(const void *a, const void *b)   /* stable: ties by index */
{
	uint32_t i = *(const uint32_t *)a, j = *(const uint32_t *)b;
	uint64_t x = swt_sort_base[i].timestamp, y = swt_sort_base[j].timestamp;
	if (x != y)
		return x < y ? -1 : 1;
	return i < j ? -1 : i > j;
}

/* stable sort by timestamp (np.argsort kind='stable'), only when the events are not in order already */
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

/* procs: comma list. Returns the number of events kept (compacted in e[]), *nfocus the focus threads. */
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
	/* the same tid can be listed twice in the table: unique */
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

#ifdef SWT_HOST_TEST
/* host test (Linux/macOS): cc -O2 -DSWT_HOST_TEST -o swt-reduce-test sweettrace.c
 *   ./swt-reduce-test FULL.swtr OUT.swtr [PROCS]   == swtr-reduce.py FULL.swtr OUT.swtr PROCS... (compare with cmp) */
int main(int argc, char **argv)
{
	if (argc < 3)
		return fprintf(stderr, "usage: %s IN OUT [PROCS]\n", argv[0]), 2;
	FILE *f = fopen(argv[1], "rb");
	if (f == NULL)
		return perror(argv[1]), 1;
	uint8_t hb[512];
	_Static_assert(sizeof(struct swt_header) == 216, "header");
	if (fread(hb, 1, 216, f) != 216)
		return fprintf(stderr, "short header\n"), 1;
	uint32_t hsize;
	uint64_t n;
	uint32_t nt;
	memcpy(&hsize, hb + offsetof(struct swt_header, header_size), 4);
	memcpy(&n, hb + offsetof(struct swt_header, n_events), 8);
	memcpy(&nt, hb + offsetof(struct swt_header, n_threads), 4);
	if (hsize > sizeof(hb) || (hsize > 216 && fread(hb + 216, 1, hsize - 216, f) != hsize - 216))
		return fprintf(stderr, "bad header\n"), 1;
	kd_buf *e = malloc(n * sizeof(kd_buf));
	struct swt_thread *t = malloc((nt + 1) * sizeof(*t));
	if (fread(e, sizeof(kd_buf), n, f) != n || fread(t, sizeof(*t), nt, f) != nt)
		return fprintf(stderr, "short file\n"), 1;
	fclose(f);
	uint64_t m = swt_prefilter(e, n);       /* as drain() does with -F */
	uint32_t nf = 0;
	uint64_t r = swt_reduce(e, m, t, nt, argc > 3 ? argv[3] : "backboardd,SpringBoard,Preferences", &nf);
	memcpy(hb + offsetof(struct swt_header, n_events), &r, 8);
	FILE *o = fopen(argv[2], "wb");
	if (o == NULL || fwrite(hb, 1, hsize, o) != hsize || fwrite(e, sizeof(kd_buf), r, o) != r ||
	    fwrite(t, sizeof(*t), nt, o) != nt || fclose(o) != 0)
		return perror(argv[2]), 1;
	printf("%s: %llu -> %llu (prefilter) -> %llu events, %u focus threads\n", argv[1], (unsigned long long)n,
	    (unsigned long long)m, (unsigned long long)r, nf);
	return 0;
}
#else

static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

/* kern.kdebug.OP[.VALUE]: KDEFLAGS, KDENABLE and KDSETBUF take VALUE as the next name; the others read or write oldp */
static int kd(int op, int value, void *buf, size_t *len)
{
	int mib[4] = { CTL_KERN, KERN_KDEBUG, op, value };
	size_t l0 = 0;
	int withval = op == KERN_KDEFLAGS || op == KERN_KDENABLE || op == KERN_KDSETBUF;
	return sysctl(mib, withval ? 4 : 3, buf, len ? len : &l0, NULL, 0);
}

static int kd_info(kbufinfo_t *bi)
{
	size_t l = sizeof(*bi);
	memset(bi, 0, sizeof(*bi));
	return kd(KERN_KDGETBUF, 0, bi, &l);
}

/* processes: pid and name, from KERN_PROC_ALL */
struct pinfo { int pid; char comm[32]; };
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

/* thread map */
static struct swt_thread *thr;
static uint32_t nthr, capthr;
static struct swt_thread *thr_get(uint64_t tid)
{
	for (uint32_t i = 0; i < nthr; i++)
		if (thr[i].tid == tid)
			return &thr[i];
	if (nthr == capthr) {
		capthr = capthr ? 2 * capthr : 4096;
		thr = realloc(thr, capthr * sizeof(*thr));
		if (thr == NULL) {
			perror("realloc");
			exit(1);
		}
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
		if (t->pid < 0)       /* valid: the pid (1 for kernproc, as launchd) */
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

static int pid_of(const char *s)
{
	char *e;
	long v = strtol(s, &e, 10);
	if (*s && *e == 0)
		return (int)v;
	int np = 0, pid = -1;
	struct pinfo *p = procs(&np);
	for (int i = 0; p != NULL && i < np; i++)
		if (strcmp(p[i].comm, s) == 0) {
			pid = p[i].pid;
			break;
		}
	free(p);
	return pid;
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

static kd_buf *ev;
static uint64_t nev, capev, maxev, dropped;
static kd_buf *chunk;
static size_t chunk_n;
static const char *focus_procs;         /* -F */
static uint64_t prefiltered;            /* events read, before -F's prefilter */

/* one KERN_KDREADTR: everything the kernel has, into ev[] */
static int drain(void)
{
	for (int round = 0; round < 64; round++) {
		size_t len = chunk_n * sizeof(kd_buf);
		if (kd(KERN_KDREADTR, 0, chunk, &len) < 0) {
			perror("KERN_KDREADTR");
			return -1;
		}
		size_t got = len;       /* the kernel returns the number of events */
		if (got == 0)
			return 0;
		size_t read_n = got;
		prefiltered += got;
		if (focus_procs != NULL)
			got = swt_prefilter(chunk, got);
		uint64_t keep = got;
		if (nev + keep > maxev) {
			keep = maxev > nev ? maxev - nev : 0;
			dropped += got - keep;
		}
		if (nev + keep > capev) {
			uint64_t c = capev ? capev : 262144;
			while (c < nev + keep)
				c *= 2;
			if (c > maxev)
				c = maxev;
			kd_buf *n = realloc(ev, c * sizeof(kd_buf));
			if (n == NULL) {
				dropped += keep;
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

static void sleep_ms(unsigned ms)
{
	struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
	while (nanosleep(&ts, &ts) < 0 && errno == EINTR && !stop) {
	}
}

int main(int argc, char **argv)
{
	unsigned secs = 10, read_ms = 100, delay = 0;
	unsigned kbufs = 1u << 20;
	const char *out = "/var/tmp/sweettrace.swtr", *pids = NULL, *extra = NULL;
	int sysc = 0, nointr = 0, nonames = 0, reset = 0, zlevel = 0, o;
	maxev = 1u << 22;
	while ((o = getopt(argc, argv, "t:o:b:m:r:d:p:c:SInRfF:zZ:")) != -1) {
		switch (o) {
		case 't': secs = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'o': out = optarg; break;
		case 'b': kbufs = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'm': maxev = strtoull(optarg, NULL, 0); break;
		case 'r': read_ms = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'd': delay = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'p': pids = optarg; break;
		case 'c': extra = optarg; break;
		case 'S': sysc = 1; break;
		case 'I': nointr = 1; break;
		case 'n': nonames = 1; break;
		case 'R': reset = 1; break;
		case 'f': focus_procs = "backboardd,SpringBoard,Preferences"; break;
		case 'F': focus_procs = optarg; break;
		case 'z': zlevel = 6; break;
		case 'Z': zlevel = atoi(optarg); zlevel = zlevel < 1 ? 1 : zlevel > 9 ? 9 : zlevel; break;
		default:
			fprintf(stderr, "usage: sweettrace [-t SECS] [-o FILE] [-b KBUFS] [-m MAX] [-r MS] [-d DELAY] [-p PIDS] "
			    "[-c CSC] [-S] [-I] [-n] [-R] [-f | -F PROCS] [-z | -Z LEVEL]\n");
			return 2;
		}
	}
	if (sizeof(kd_buf) != 64) {
		fprintf(stderr, "kd_buf is %zu bytes, not 64\n", sizeof(kd_buf));
		return 1;
	}
	if (reset) {
		if (kd(KERN_KDREMOVE, 0, NULL, NULL) < 0)
			return perror("KERN_KDREMOVE"), 1;
		printf("kdebug reset\n");
		return 0;
	}
	FILE *f = fopen(out, "wb");
	if (f == NULL)
		return perror(out), 1;
	if (delay)
		sleep(delay);
	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);
	signal(SIGHUP, on_sig);

	if (kd(KERN_KDREMOVE, 0, NULL, NULL) < 0) {
		fprintf(stderr, "KERN_KDREMOVE: %s (root needed; EBUSY: someone else traces, sweettrace -R)\n", strerror(errno));
		return 1;
	}
	kbufinfo_t bi;
	for (;;) {
		if (kd(KERN_KDSETBUF, (int)kbufs, NULL, NULL) < 0)
			return perror("KERN_KDSETBUF"), 1;
		if (kd(KERN_KDSETUP, 0, NULL, NULL) == 0)
			break;
		if (kbufs <= 65536)
			return perror("KERN_KDSETUP"), 1;
		kbufs /= 2;
	}
	if (kd_info(&bi) == 0 && bi.nkdbufs > 0)
		kbufs = (unsigned)bi.nkdbufs;

	static uint8_t tf[TYPEFILTER_SIZE];
	tf_allow(tf, DBG_TRACE, -1);
	tf_allow(tf, DBG_MACH, DBG_MACH_SCHED);
	tf_allow(tf, DBG_MACH, DBG_MACH_IPC);
	if (!nointr)
		tf_allow(tf, DBG_MACH, DBG_MACH_EXCP_INTR);
	tf_allow(tf, DBG_DRIVERS, SWEET_SUBCLASS);
	if (sysc) {
		tf_allow(tf, DBG_MACH, DBG_MACH_EXCP_SC);
		tf_allow(tf, DBG_BSD, DBG_BSD_EXCP_SC);
		tf_allow(swt_whole, DBG_MACH, DBG_MACH_EXCP_SC);
		tf_allow(swt_whole, DBG_BSD, DBG_BSD_EXCP_SC);
	}
	if (extra != NULL) {
		char *s = strdup(extra), *save = NULL;
		for (char *t = strtok_r(s, ",", &save); t; t = strtok_r(NULL, ",", &save)) {
			char *sl = strchr(t, '/');
			unsigned c = (unsigned)strtoul(t, NULL, 0);
			int sub = sl ? (int)strtoul(sl + 1, NULL, 0) : -1;
			if (c < 256 && sub < 256) {
				tf_allow(tf, c, sub);
				tf_allow(swt_whole, c, sub);   /* asked for: kept whole under -F */
			}
		}
		free(s);
	}
	size_t tl = sizeof(tf);         /* the kernel copies the filter in from oldp, oldlen = its size */
	if (kd(KERN_KDSET_TYPEFILTER, 0, tf, &tl) < 0) {
		perror("KERN_KDSET_TYPEFILTER");
		kd(KERN_KDREMOVE, 0, NULL, NULL);
		return 1;
	}
	if (pids != NULL) {
		char *s = strdup(pids), *save = NULL;
		for (char *t = strtok_r(s, ",", &save); t; t = strtok_r(NULL, ",", &save)) {
			int pid = pid_of(t);
			kd_regtype r = { KDBG_TYPENONE, (unsigned)pid, 1, 0, 0 };
			size_t rl = sizeof(r);
			if (pid < 0 || kd(KERN_KDPIDTR, 0, &r, &rl) < 0)
				fprintf(stderr, "pid filter %s: %s\n", t, pid < 0 ? "no such process" : strerror(errno));
			else
				printf("pid filter: %s = %d\n", t, pid);
		}
		free(s);
	}
	if (read_ms == 0)
		kd(KERN_KDEFLAGS, KDBG_NOWRAP, NULL, NULL);

	chunk_n = kbufs < 262144 ? kbufs : 262144;
	chunk = malloc(chunk_n * sizeof(kd_buf));
	if (chunk == NULL) {
		kd(KERN_KDREMOVE, 0, NULL, NULL);
		return perror("malloc"), 1;
	}
	if (!nonames)
		map_names();    /* before: threads that exit during the trace keep their names */

	struct timespec wall;
	clock_gettime(CLOCK_REALTIME, &wall);
	uint64_t t0 = mach_absolute_time();
	if (kd(KERN_KDENABLE, KDEBUG_ENABLE_TRACE, NULL, NULL) < 0) {
		perror("KERN_KDENABLE");
		kd(KERN_KDREMOVE, 0, NULL, NULL);
		return 1;
	}
	/* the map of every thread, made at enable (read once) */
	if (kd_info(&bi) == 0 && bi.nkdthreads > 0) {
		size_t ml = (size_t)bi.nkdthreads * sizeof(kd_threadmap);
		kd_threadmap *m = malloc(ml);
		if (m != NULL && kd(KERN_KDTHRMAP, 0, m, &ml) == 0)
			map_kdebug(m, ml / sizeof(kd_threadmap));
		free(m);
	}
	printf("sweettrace: %u s, kernel buffer %u events, reading every %u ms, pid %d -> %s\n", secs, kbufs, read_ms,
	    getpid(), out);
	fflush(stdout);

	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	uint64_t dur = (uint64_t)secs * 1000000000ull * tb.denom / tb.numer;
	uint32_t reads = 0;
	while (!stop && mach_absolute_time() - t0 < dur) {
		if (read_ms == 0) {
			sleep_ms(100);
			continue;
		}
		sleep_ms(read_ms);
		if (drain() < 0)
			break;
		reads++;
	}
	kd(KERN_KDENABLE, 0, NULL, NULL);
	uint64_t t1 = mach_absolute_time();
	drain();
	kd_info(&bi);
	{
		/* threads that came during the trace */
		size_t ml = 32768 * sizeof(kd_threadmap);       /* no size query: room for 32768 threads */
		kd_threadmap *m = malloc(ml);
		if (m != NULL && kd(KERN_KDREADCURTHRMAP, 0, m, &ml) == 0)
			map_kdebug(m, ml / sizeof(kd_threadmap));
		free(m);
	}
	kd(KERN_KDREMOVE, 0, NULL, NULL);
	if (!nonames)
		map_names();
	uint64_t nev_read = nev;
	uint32_t nfocus = 0;
	uint64_t r0 = mach_absolute_time();
	if (focus_procs != NULL)
		nev = swt_reduce(ev, nev, thr, nthr, focus_procs, &nfocus);
	uint64_t r1 = mach_absolute_time();

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
	{
		int nc = 0;
		size_t l = sizeof(nc);
		sysctlbyname("hw.ncpu", &nc, &l, NULL, 0);
		h.ncpu = (uint32_t)nc;
	}
	h.kd_flags = bi.flags;
	h.kbufs = kbufs;
	h.reads = reads;
	h.dropped = (uint32_t)dropped;
	h.tracer_pid = getpid();
	h.read_ms = read_ms;
	h.start_wall_ns = (uint64_t)wall.tv_sec * 1000000000ull + (uint64_t)wall.tv_nsec;
	{
		size_t w = 0;
		for (int i = 1; i < argc && w < sizeof(h.args) - 1; i++)
			w += (size_t)snprintf(h.args + w, sizeof(h.args) - w, "%s%s", i > 1 ? " " : "", argv[i]);
	}
	if (zlevel > 0) {
		/* gzip (deflate in 4 MB pieces: gzwrite takes an unsigned length) */
		char mode[8];
		snprintf(mode, sizeof(mode), "wb%d", zlevel);
		fflush(f);
		gzFile g = gzdopen(dup(fileno(f)), mode);
		int bad = g == NULL || gzbuffer(g, 1 << 20) != 0 || gzwrite(g, &h, sizeof(h)) != (int)sizeof(h);
		const uint8_t *parts[2] = { (const uint8_t *)ev, (const uint8_t *)thr };
		uint64_t lens[2] = { nev * sizeof(kd_buf), (uint64_t)nthr * sizeof(*thr) };
		for (int k = 0; !bad && k < 2; k++)
			for (uint64_t off = 0; !bad && off < lens[k]; off += 4u << 20) {
				unsigned piece = (unsigned)(lens[k] - off < (4u << 20) ? lens[k] - off : (4u << 20));
				bad = gzwrite(g, parts[k] + off, piece) != (int)piece;
			}
		if (g != NULL && gzclose(g) != Z_OK)
			bad = 1;
		if (bad || fclose(f) != 0) {
			fprintf(stderr, "%s: gzip write failed\n", out);
			return 1;
		}
	} else if (fwrite(&h, sizeof(h), 1, f) != 1 || (nev && fwrite(ev, sizeof(kd_buf), nev, f) != nev) ||
	    (nthr && fwrite(thr, sizeof(*thr), nthr, f) != nthr) || fclose(f) != 0) {
		perror(out);
		return 1;
	}
	uint64_t w1 = mach_absolute_time();
	if (focus_procs != NULL || zlevel > 0) {
		FILE *sf = fopen(out, "rb");
		long fsz = -1;
		if (sf != NULL && fseek(sf, 0, SEEK_END) == 0)
			fsz = ftell(sf);
		if (sf != NULL)
			fclose(sf);
		printf("sweettrace: reduce %s: %llu read, %llu after prefilter, %llu kept (%u focus threads) in %.0f ms; "
		    "write%s %ld bytes in %.0f ms\n", focus_procs ? focus_procs : "off", (unsigned long long)prefiltered,
		    (unsigned long long)nev_read, (unsigned long long)nev, nfocus,
		    (double)(r1 - r0) * tb.numer / tb.denom / 1e6, zlevel ? " (gzip)" : "", fsz,
		    (double)(w1 - r1) * tb.numer / tb.denom / 1e6);
	}
	double s = (double)(t1 - t0) * tb.numer / tb.denom / 1e9;
	printf("sweettrace: %llu events in %.2f s (%.0f/s), %u threads, %u reads%s%s -> %s\n", (unsigned long long)nev, s,
	    s > 0 ? nev / s : 0, nthr, reads, (bi.flags & KDBG_WRAPPED) ? ", KERNEL BUFFER WRAPPED (events lost)" : "",
	    dropped ? ", -m reached (events dropped)" : "", out);
	return 0;
}
#endif /* SWT_HOST_TEST */
