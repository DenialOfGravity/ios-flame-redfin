/*
 * fastrpcd transport: what Linux's/Android's fastrpc kernel driver does for hexagonrpcd, in userland,
 * over /dev/redwood-fastrpc (XNU patch 0950) and physical buffers read and written through /dev/pmem.
 *
 * One call = one 40-byte message on the channel and one answer back (kernel: 16 or 32 bytes, matched by
 * ctx). The arguments travel in one physically contiguous buffer below 4 GiB, laid out as Android's
 * adsprpc.c get_args() does (see transport.h, frpc_layout()). The DSP reaches the buffer through SMMU
 * stream 0x1403, which the kernel gives a translation-off context bank (FASTRPC_SMMU_IDENTITY), so
 * the DSP's address is the physical address with the session (3) in bits 32+.
 *
 * Copyright (C) 2026 the ios-flame contributors. GPL-3.0-or-later (part of fastrpcd).
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/time.h>

#include <libhexagonrpc/hexagonrpc.h>
#include "log.h"
#include "transport.h"

/* ---- the layout ---- */

struct remote_buf64 {
	uint64_t pv, len;
};
struct smq_invoke_buf {
	int32_t num, pgidx;
};
struct smq_phy_page {
	uint64_t addr, size;
};

#define ALIGN_UP(x, a)	(((x) + (a) - 1) & ~((uint64_t)(a) - 1))
#define PAGE_OF(x)	((x) & ~(uint64_t)(FRPC_PAGE - 1))

static size_t meta_len(unsigned n)
{
	return n * (sizeof(struct remote_buf64) + sizeof(struct smq_invoke_buf) + sizeof(struct smq_phy_page)) +
	       FRPC_FDLIST * sizeof(uint64_t) + FRPC_CRCLIST * sizeof(uint32_t) + sizeof(uint32_t);
}

/* Bytes the layout of this call needs (metadata + every buffer at its 128-byte boundary), 0 if impossible. */
static size_t layout_need(uint32_t sc, const struct fastrpc_invoke_args *args)
{
	unsigned n = REMOTE_SCALARS_INBUFS(sc) + REMOTE_SCALARS_OUTBUFS(sc), i;
	size_t off;

	if (sc & 0xff || n > FRPC_MAX_BUFS)
		return 0;
	off = meta_len(n);
	for (i = 0; i < n; i++)
		if (args[i].length)
			off = ALIGN_UP(off, FRPC_ALIGN) + args[i].length;
	return off;
}

int frpc_layout(uint32_t sc, const struct fastrpc_invoke_args *args, uint64_t pa, uint32_t session,
		uint8_t *img, size_t cap, struct frpc_layout *lay)
{
	unsigned in = REMOTE_SCALARS_INBUFS(sc), n = in + REMOTE_SCALARS_OUTBUFS(sc), i;
	struct remote_buf64 rpra;
	struct smq_invoke_buf list;
	struct smq_phy_page page;
	size_t off, need = layout_need(sc, args);
	uint8_t *p_rpra, *p_list, *p_pages;

	if (need == 0 || need > cap)
		return -1;
	memset(lay, 0, sizeof(*lay));
	lay->metalen = meta_len(n);
	memset(img, 0, lay->metalen);	/* also fdlist, crclist and the early-wake hint */
	p_rpra = img;
	p_list = p_rpra + n * sizeof(rpra);
	p_pages = p_list + n * sizeof(list);
	off = lay->metalen;
	for (i = 0; i < n; i++) {
		uint64_t len = args[i].length, at;

		list.num = len ? 1 : 0;
		list.pgidx = (int32_t)i;
		rpra.len = len;
		rpra.pv = 0;
		page.addr = page.size = 0;
		if (len) {
			off = ALIGN_UP(off, FRPC_ALIGN);
			at = pa + off;
			rpra.pv = at;
			page.addr = PAGE_OF(at) | (uint64_t)session << 32;
			page.size = ((PAGE_OF(at + len - 1) - PAGE_OF(at)) / FRPC_PAGE + 1) * FRPC_PAGE;
			lay->off[i] = off;
			if (i < in && args[i].ptr)
				memcpy(img + off, (const void *)(uintptr_t)args[i].ptr, len);
			else
				memset(img + off, 0, len);	/* outputs start zeroed */
			off += len;
		}
		memcpy(p_rpra + i * sizeof(rpra), &rpra, sizeof(rpra));
		memcpy(p_list + i * sizeof(list), &list, sizeof(list));
		memcpy(p_pages + i * sizeof(page), &page, sizeof(page));
	}
	lay->used = off;
	return 0;
}

/* ---- calls in flight ---- */

#define SLOTS		64	/* ctx bits 4-9 (adsprpc: FASTRPC_CTXID_MASK 0xff0) */
#define SESSIONS	8
#define EARLY_GRACE_MS	50

struct slot {
	int busy, done, early;
	uint64_t ctx;
	int32_t result;
};

struct buf {
	uint64_t pa, size;
	int busy;
};

static struct {
	struct frpc_dev dev;
	struct frpc_mem mem;
	pthread_t reader;
	int started, dead, stopping;
	pthread_mutex_t lock;
	pthread_cond_t cond;
	struct slot slot[SLOTS];
	struct buf buf[FRPC_MAX_BUFS];
	struct {
		int used;
		int32_t client;
		uint32_t pd;
	} session[SESSIONS];
	uint32_t next_slot;
} T = { .lock = PTHREAD_MUTEX_INITIALIZER, .cond = PTHREAD_COND_INITIALIZER };

int frpc_mmap_method = 4;

int frpc_dead(void)
{
	return T.dead;
}

static void *reader_main(void *unused)
{
	uint8_t a[64];

	(void)unused;
	for (;;) {
		int n = T.dev.recv(T.dev.ctx, a, sizeof(a));
		uint64_t ctx;
		int32_t result;
		uint32_t flags = 0, idx;

		if (n < 0) {
			if (errno == EINTR || errno == EAGAIN)
				continue;
			pthread_mutex_lock(&T.lock);
			if (!T.stopping)
				flog("answers: read: %s%s", strerror(errno),
				     errno == ECONNRESET ? " -- the DSP has gone" : "");
			T.dead = 1;
			pthread_cond_broadcast(&T.cond);
			pthread_mutex_unlock(&T.lock);
			return NULL;
		}
		if (n < 12) {
			flog("answers: short answer (%d bytes), ignored", n);
			continue;
		}
		memcpy(&ctx, a, 8);
		memcpy(&result, a + 8, 4);
		if (n >= 16 + 8)
			memcpy(&flags, a + 12, 4);	/* smq_invoke_rspv2 {ctx, retval, flags, earlyWakeTime, version} */
		idx = (uint32_t)(ctx >> 4) & (SLOTS - 1);
		pthread_mutex_lock(&T.lock);
		if (!T.slot[idx].busy || (T.slot[idx].ctx & ~0xfull) != (ctx & ~0xfull)) {
			pthread_mutex_unlock(&T.lock);
			flog("answers: ctx %#llx result %d matches no call in flight, ignored", (unsigned long long)ctx, result);
			continue;
		}
		switch (flags) {
		case 2:		/* USER_EARLY_SIGNAL: a hint only */
			break;
		case 1:		/* EARLY_RESPONSE: the result, the completion may follow */
			T.slot[idx].result = result;
			T.slot[idx].early = 1;
			break;
		case 3:		/* COMPLETE_SIGNAL: the result came earlier */
			if (!T.slot[idx].early)
				T.slot[idx].result = result;
			T.slot[idx].done = 1;
			break;
		default:	/* NORMAL_RESPONSE */
			T.slot[idx].result = result;
			T.slot[idx].done = 1;
			break;
		}
		pthread_cond_broadcast(&T.cond);
		pthread_mutex_unlock(&T.lock);
		vlog("< ctx %#llx result %d (%#x)%s", (unsigned long long)ctx, result, (unsigned)result,
		     flags ? (flags == 1 ? " early" : flags == 2 ? " hint" : " complete") : "");
	}
}

int frpc_start(const struct frpc_dev *dev, const struct frpc_mem *mem)
{
	T.dev = *dev;
	T.mem = *mem;
	T.dead = T.stopping = 0;
	memset(T.slot, 0, sizeof(T.slot));
	memset(T.session, 0, sizeof(T.session));
	memset(T.buf, 0, sizeof(T.buf));
	if (pthread_create(&T.reader, NULL, reader_main, NULL)) {
		errno = EAGAIN;
		return -1;
	}
	T.started = 1;
	return 0;
}

void frpc_stop(void)
{
	if (!T.started)
		return;
	pthread_mutex_lock(&T.lock);
	T.stopping = 1;
	pthread_mutex_unlock(&T.lock);
	pthread_cancel(T.reader);
	pthread_join(T.reader, NULL);
	T.started = 0;
}

int frpc_session_new(int32_t client)
{
	int i;

	pthread_mutex_lock(&T.lock);
	for (i = 0; i < SESSIONS; i++)
		if (!T.session[i].used) {
			T.session[i].used = 1;
			T.session[i].client = client;
			T.session[i].pd = FRPC_ROOT_PD;
			pthread_mutex_unlock(&T.lock);
			return i;
		}
	pthread_mutex_unlock(&T.lock);
	errno = EMFILE;
	return -1;
}

/* A buffer of at least size bytes, from the ones we have or a new one (sizes in a few classes, so that
 * the kernel's pool -- 32 entries, reused only at the same size -- serves a restarted daemon). */
static int buf_get(uint64_t size, uint64_t *pa)
{
	static const uint64_t classes[] = { 64u << 10, 1u << 20, 4u << 20, 16u << 20 };
	uint64_t want = 0;
	unsigned i;
	int best = -1, free_ent = -1;

	for (i = 0; i < sizeof(classes) / sizeof(*classes); i++)
		if (size <= classes[i]) {
			want = classes[i];
			break;
		}
	if (!want) {
		errno = E2BIG;
		return -1;
	}
	pthread_mutex_lock(&T.lock);
	for (i = 0; i < FRPC_MAX_BUFS; i++) {
		if (T.buf[i].size == 0) {
			if (free_ent < 0)
				free_ent = (int)i;
		} else if (!T.buf[i].busy && T.buf[i].size >= size &&
			   (best < 0 || T.buf[i].size < T.buf[best].size)) {
			best = (int)i;
		}
	}
	if (best >= 0) {
		T.buf[best].busy = 1;
		*pa = T.buf[best].pa;
		pthread_mutex_unlock(&T.lock);
		return 0;
	}
	if (free_ent < 0) {
		pthread_mutex_unlock(&T.lock);
		errno = ENOSPC;
		return -1;
	}
	T.buf[free_ent].size = want;	/* reserved */
	T.buf[free_ent].busy = 1;
	pthread_mutex_unlock(&T.lock);
	if (T.mem.alloc(T.mem.ctx, want, pa)) {
		int e = errno;

		pthread_mutex_lock(&T.lock);
		T.buf[free_ent].size = 0;
		T.buf[free_ent].busy = 0;
		pthread_mutex_unlock(&T.lock);
		flog("no %llu-byte buffer for the DSP: %s", (unsigned long long)want, strerror(e));
		errno = e;
		return -1;
	}
	if (*pa + want > 0x100000000ull) {
		flog("buffer at %#llx is not below 4 GiB: not used", (unsigned long long)*pa);
		errno = ENOMEM;
		return -1;	/* the entry stays reserved: never hand it out */
	}
	pthread_mutex_lock(&T.lock);
	T.buf[free_ent].pa = *pa;
	pthread_mutex_unlock(&T.lock);
	vlog("buffer %u: %llu bytes at %#llx", free_ent, (unsigned long long)want, (unsigned long long)*pa);
	return 0;
}

static void buf_put(uint64_t pa)
{
	unsigned i;

	pthread_mutex_lock(&T.lock);
	for (i = 0; i < FRPC_MAX_BUFS; i++)
		if (T.buf[i].size && T.buf[i].pa == pa)
			T.buf[i].busy = 0;
	pthread_mutex_unlock(&T.lock);
}

static int thread_id(void)
{
	return (int)getpid();
}

/* One call: lay out, send, wait, copy the outputs back. -1 + errno, or the DSP's result. */
static int invoke(int fd, uint32_t handle, uint32_t sc, const struct fastrpc_invoke_args *args)
{
	struct frpc_layout lay;
	struct frpc_msg m;
	unsigned in = REMOTE_SCALARS_INBUFS(sc), n = in + REMOTE_SCALARS_OUTBUFS(sc), i, idx = 0;
	size_t need = layout_need(sc, args);
	uint64_t pa;
	uint8_t *img;
	int ret, found = 0;

	if (fd < 0 || fd >= SESSIONS || !T.session[fd].used) {
		errno = EBADF;
		return -1;
	}
	if (T.dead) {
		errno = ECONNRESET;
		return -1;
	}
	if (need == 0) {
		flog("invoke handle %u sc %#x: handles or > %d buffers are not supported", handle, sc, FRPC_MAX_BUFS);
		errno = EINVAL;
		return -1;
	}
	if (buf_get(need, &pa))
		return -1;
	img = malloc(need);
	if (img == NULL) {
		buf_put(pa);
		errno = ENOMEM;
		return -1;
	}
	if (frpc_layout(sc, args, pa, FRPC_SESSION, img, need, &lay) || T.mem.wr(T.mem.ctx, pa, img, lay.used)) {
		free(img);
		buf_put(pa);
		errno = EIO;
		return -1;
	}
	free(img);

	pthread_mutex_lock(&T.lock);
	for (i = 0; i < SLOTS && !found; i++) {
		idx = 1 + (T.next_slot + i) % (SLOTS - 1);	/* 1..63 */
		if (!T.slot[idx].busy)
			found = 1;
	}
	if (!found) {
		pthread_mutex_unlock(&T.lock);
		buf_put(pa);
		errno = EBUSY;
		return -1;
	}
	T.next_slot = idx;
	memset(&T.slot[idx], 0, sizeof(T.slot[idx]));
	T.slot[idx].busy = 1;
	T.slot[idx].ctx = (uint64_t)idx << 4 | T.session[fd].pd;
	m.client = handle == FRPC_INIT_HANDLE ? 0 : T.session[fd].client;	/* the kernel's own calls: pid 0 */
	m.thread = thread_id();
	m.ctx = T.slot[idx].ctx;
	m.handle = handle;
	m.sc = sc;
	m.addr = pa | (uint64_t)FRPC_SESSION << 32;
	m.size = ALIGN_UP(lay.used, FRPC_PAGE);
	pthread_mutex_unlock(&T.lock);

	vlog("> client %d ctx %#llx handle %u sc %#x (m%u %u/%u) at %#llx, %zu bytes", m.client, (unsigned long long)m.ctx,
	     handle, sc, REMOTE_SCALARS_METHOD(sc), in, n - in, (unsigned long long)pa, lay.used);
	if (T.dev.send(T.dev.ctx, &m)) {
		int e = errno;

		pthread_mutex_lock(&T.lock);
		T.slot[idx].busy = 0;
		pthread_mutex_unlock(&T.lock);
		buf_put(pa);
		if (e == ECONNRESET)
			T.dead = 1;
		errno = e;
		return -1;
	}

	pthread_mutex_lock(&T.lock);
	while (!T.slot[idx].done && !T.dead) {
		if (T.slot[idx].early) {
			struct timespec ts;
			struct timeval tv;

			gettimeofday(&tv, NULL);
			ts.tv_sec = tv.tv_sec;
			ts.tv_nsec = tv.tv_usec * 1000 + EARLY_GRACE_MS * 1000000L;
			ts.tv_sec += ts.tv_nsec / 1000000000L;
			ts.tv_nsec %= 1000000000L;
			if (pthread_cond_timedwait(&T.cond, &T.lock, &ts) == ETIMEDOUT)
				T.slot[idx].done = 1;
		} else {
			pthread_cond_wait(&T.cond, &T.lock);
		}
	}
	if (!T.slot[idx].done) {
		T.slot[idx].busy = 0;
		pthread_mutex_unlock(&T.lock);
		/* the DSP may still write the buffer: never reuse it */
		errno = ECONNRESET;
		return -1;
	}
	ret = T.slot[idx].result;
	T.slot[idx].busy = 0;
	pthread_mutex_unlock(&T.lock);

	if (ret == 0)
		for (i = in; i < n; i++)
			if (args[i].length && args[i].ptr &&
			    T.mem.rd(T.mem.ctx, pa + lay.off[i], (void *)(uintptr_t)args[i].ptr, args[i].length)) {
				ret = -1;
				errno = EIO;
				break;
			}
	buf_put(pa);
	return ret;
}

/* INIT_MMAP (handle 1): give the DSP pages of ours for its heap. */
static int init_mmap(int fd, int method, uint32_t flags, uint64_t vaddrin, uint64_t pa, uint64_t size, uint64_t *vout)
{
	struct {
		int32_t pid;
		uint32_t flags;
		uint64_t vaddrin;
		int32_t num;
		int32_t pad;
	} inargs = { T.session[fd].client, flags, vaddrin, method == 2 ? 1 : (int32_t)sizeof(struct smq_phy_page), 0 };
	struct smq_phy_page page = { pa | (uint64_t)FRPC_SESSION << 32, size };
	uint64_t out = 0;
	struct fastrpc_invoke_args a[3] = {
		{ (uint64_t)(uintptr_t)&inargs, sizeof(inargs), -1, 0 },
		{ (uint64_t)(uintptr_t)&page, sizeof(page), -1, 0 },
		{ (uint64_t)(uintptr_t)&out, sizeof(out), -1, 0 },
	};
	int ret = invoke(fd, FRPC_INIT_HANDLE, REMOTE_SCALARS_MAKE(method, 2, 1), a);

	*vout = out;
	return ret;
}

static int do_mmap(int fd, struct fastrpc_req_mmap *r)
{
	uint64_t size = ALIGN_UP(r->size, FRPC_PAGE), pa, vout = 0;
	int ret, other;

	if (r->fd != -1) {
		flog("mmap of a dma-buf (fd %d) is not supported", r->fd);
		errno = EINVAL;
		return -1;
	}
	if (size == 0 || size > (16u << 20)) {
		flog("mmap of %llu bytes: not supported (1 byte .. 16 MiB)", (unsigned long long)r->size);
		errno = EINVAL;
		return -1;
	}
	if (T.mem.alloc(T.mem.ctx, size, &pa)) {
		flog("mmap: no %llu bytes for the DSP: %s", (unsigned long long)size, strerror(errno));
		return -1;
	}
	if (pa + size > 0x100000000ull) {
		flog("mmap: RAM at %#llx is not below 4 GiB", (unsigned long long)pa);
		errno = ENOMEM;
		return -1;
	}
	ret = init_mmap(fd, frpc_mmap_method, r->flags, r->vaddrin, pa, size, &vout);
	flog("INIT_MMAP (method %d) flags %#x %llu bytes at %#llx -> %d, DSP address %#llx", frpc_mmap_method, r->flags,
	     (unsigned long long)size, (unsigned long long)pa, ret, (unsigned long long)vout);
	if (ret != 0 && !T.dead) {
		other = frpc_mmap_method == 4 ? 2 : 4;
		ret = init_mmap(fd, other, r->flags, r->vaddrin, pa, size, &vout);
		flog("INIT_MMAP (method %d) retry -> %d, DSP address %#llx%s", other, ret, (unsigned long long)vout,
		     ret == 0 ? ": using this method from now on" : "");
		if (ret == 0)
			frpc_mmap_method = other;
	}
	/* the pages stay the DSP's even on failure (it may have kept a mapping): never reused */
	if (ret == 0)
		r->vaddrout = vout;
	return ret;
}

static int attach(int fd, uint32_t pd)
{
	int32_t tgid = T.session[fd].client;
	struct fastrpc_invoke_args a = { (uint64_t)(uintptr_t)&tgid, sizeof(tgid), -1, 0 };
	int ret;

	T.session[fd].pd = pd;
	ret = invoke(fd, FRPC_INIT_HANDLE, REMOTE_SCALARS_MAKE(0, 1, 0), &a);
	if (ret == -1 && errno == ENOTCONN)
		return ret;	/* the channel is not open yet: the caller waits (and says so once) */
	flog("INIT_ATTACH%s (pd %u, tgid %d) -> %d%s%s", pd == FRPC_SENSORS_PD ? "_SNS" : "", pd, tgid, ret,
	     ret == -1 ? ": " : "", ret == -1 ? strerror(errno) : "");
	return ret;
}

int fastrpc_ioctl(int fd, unsigned long request, void *arg)
{
	struct fastrpc_invoke *inv;

	if (fd < 0 || fd >= SESSIONS || !T.session[fd].used) {
		errno = EBADF;
		return -1;
	}
	switch (request) {
	case FASTRPC_IOCTL_INVOKE:
		inv = arg;
		return invoke(fd, inv->handle, inv->sc, (const struct fastrpc_invoke_args *)(uintptr_t)inv->args);
	case FASTRPC_IOCTL_INIT_ATTACH:
		return attach(fd, FRPC_ROOT_PD);
	case FASTRPC_IOCTL_INIT_ATTACH_SNS:
		return attach(fd, FRPC_SENSORS_PD);
	case FASTRPC_IOCTL_MMAP:
		return do_mmap(fd, arg);
	case FASTRPC_IOCTL_MUNMAP:
		flog("munmap: not supported (the DSP keeps its pages)");
		errno = ENOTSUP;
		return -1;
	default:
		errno = ENOTTY;
		return -1;
	}
}

/* ---- the real device: /dev/redwood-fastrpc + /dev/pmem ---- */

struct fastrpc_smmu_identity {
	uint32_t sid;
};
struct fastrpc_alloc {
	uint64_t size, pa;
};
#define FASTRPC_SMMU_IDENTITY	_IOW('f', 1, struct fastrpc_smmu_identity)
#define FASTRPC_ALLOC		_IOWR('f', 2, struct fastrpc_alloc)

static int dev_fd = -1;
static int pmem_fd = -1;

static int dev_send(void *ctx, const struct frpc_msg *m)
{
	ssize_t n;

	(void)ctx;
	do
		n = write(dev_fd, m, sizeof(*m));
	while (n < 0 && errno == EINTR);
	if (n == (ssize_t)sizeof(*m))
		return 0;
	if (n >= 0)
		errno = EIO;
	return -1;
}

static int dev_recv(void *ctx, void *answer, size_t cap)
{
	(void)ctx;
	return (int)read(dev_fd, answer, cap);
}

static int dev_alloc(void *ctx, uint64_t size, uint64_t *pa)
{
	struct fastrpc_alloc a = { size, 0 };

	(void)ctx;
	if (ioctl(dev_fd, FASTRPC_ALLOC, &a) < 0)
		return -1;
	*pa = a.pa;
	return 0;
}

/*
 * The buffers are GPU-pool RAM that XNU does not map: /dev/pmem reaches it through a device mapping
 * (uncached: nothing to flush) and takes only 32-bit aligned offsets and lengths. Unaligned edges go
 * through a bounce buffer (read, patch, write back).
 */
static int pmem_xfer(uint64_t pa, void *buf, size_t len, int write)
{
	uint64_t lo = pa & ~3ull, hi = (pa + len + 3) & ~3ull;
	size_t n = (size_t)(hi - lo);
	uint8_t *tmp;
	int ok;

	if (lo == pa && n == len) {
		ssize_t r = write ? pwrite(pmem_fd, buf, len, (off_t)pa) : pread(pmem_fd, buf, len, (off_t)pa);

		ok = r == (ssize_t)len;
	} else {
		tmp = malloc(n);
		if (tmp == NULL)
			return -1;
		ok = pread(pmem_fd, tmp, n, (off_t)lo) == (ssize_t)n;
		if (ok && write) {
			memcpy(tmp + (pa - lo), buf, len);
			ok = pwrite(pmem_fd, tmp, n, (off_t)lo) == (ssize_t)n;
		} else if (ok) {
			memcpy(buf, tmp + (pa - lo), len);
		}
		free(tmp);
	}
	if (ok)
		return 0;
	flog("pmem: %s %zu at %#llx: %s", write ? "write" : "read", len, (unsigned long long)pa, strerror(errno));
	return -1;
}

static int pmem_wr(void *ctx, uint64_t pa, const void *buf, size_t len)
{
	(void)ctx;
	return pmem_xfer(pa, (void *)(uintptr_t)buf, len, 1);
}

static int pmem_rd(void *ctx, uint64_t pa, void *buf, size_t len)
{
	(void)ctx;
	return pmem_xfer(pa, buf, len, 0);
}

int frpc_open_device(const char *path, struct frpc_dev *dev, struct frpc_mem *mem)
{
	struct fastrpc_smmu_identity id = { FRPC_SID };
	int e;

	if (pmem_fd < 0) {
		pmem_fd = open("/dev/pmem", O_RDWR);
		if (pmem_fd < 0) {
			e = errno;
			flog("/dev/pmem: %s (boot-arg sweetpmem=1, run as root)", strerror(e));
			errno = e;
			return -1;
		}
	}
	dev_fd = open(path, O_RDWR);
	if (dev_fd < 0) {
		e = errno;
		flog("%s: %s%s", path, strerror(e),
		     e == ENOENT ? " (kernel without 0950, or boot-arg adsp_fastrpc=0, or adsp=0)" :
		     e == EBUSY ? " (another fastrpcd has it open)" : "");
		errno = e;
		return -1;
	}
	if (ioctl(dev_fd, FASTRPC_SMMU_IDENTITY, &id) < 0) {
		e = errno;
		flog("FASTRPC_SMMU_IDENTITY %#x: %s (see the SWEET FASTRPC: SMMU line in the klog)", FRPC_SID, strerror(e));
		close(dev_fd);
		dev_fd = -1;
		errno = e;
		return -1;
	}
	flog("%s open; SMMU stream %#x is session %u", path, FRPC_SID, FRPC_SESSION);
	dev->send = dev_send;
	dev->recv = dev_recv;
	dev->ctx = NULL;
	mem->alloc = dev_alloc;
	mem->wr = pmem_wr;
	mem->rd = pmem_rd;
	mem->ctx = NULL;
	return 0;
}

void frpc_close_device(void)
{
	if (dev_fd >= 0)
		close(dev_fd);
	dev_fd = -1;
}
