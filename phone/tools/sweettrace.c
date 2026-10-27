/*
 * sweettrace: record a kdebug trace for the frame-pacing analysis (tools-claude/sweet-trace.py).
 *
 *   sweettrace [-t SECS] [-o FILE] [-b KBUFS] [-m MAXEVENTS] [-r MS] [-d DELAY] [-p PID,...] [-c CLASS[/SUB],...]
 *              [-S] [-I] [-n]
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
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/proc.h>

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
		if (got < chunk_n)
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
	int sysc = 0, nointr = 0, nonames = 0, reset = 0, o;
	maxev = 1u << 22;
	while ((o = getopt(argc, argv, "t:o:b:m:r:d:p:c:SInR")) != -1) {
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
		default:
			fprintf(stderr, "usage: sweettrace [-t SECS] [-o FILE] [-b KBUFS] [-m MAX] [-r MS] [-d DELAY] [-p PIDS] "
			    "[-c CSC] [-S] [-I] [-n] [-R]\n");
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
	}
	if (extra != NULL) {
		char *s = strdup(extra), *save = NULL;
		for (char *t = strtok_r(s, ",", &save); t; t = strtok_r(NULL, ",", &save)) {
			char *sl = strchr(t, '/');
			unsigned c = (unsigned)strtoul(t, NULL, 0);
			int sub = sl ? (int)strtoul(sl + 1, NULL, 0) : -1;
			if (c < 256 && sub < 256)
				tf_allow(tf, c, sub);
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
	if (fwrite(&h, sizeof(h), 1, f) != 1 || (nev && fwrite(ev, sizeof(kd_buf), nev, f) != nev) ||
	    (nthr && fwrite(thr, sizeof(*thr), nthr, f) != nthr) || fclose(f) != 0) {
		perror(out);
		return 1;
	}
	double s = (double)(t1 - t0) * tb.numer / tb.denom / 1e9;
	printf("sweettrace: %llu events in %.2f s (%.0f/s), %u threads, %u reads%s%s -> %s\n", (unsigned long long)nev, s,
	    s > 0 ? nev / s : 0, nthr, reads, (bi.flags & KDBG_WRAPPED) ? ", KERNEL BUFFER WRAPPED (events lost)" : "",
	    dropped ? ", -m reached (events dropped)" : "", out);
	return 0;
}
