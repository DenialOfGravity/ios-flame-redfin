/*
 * fastrpcd host tests: the argument layout against hand-computed bytes, a fake DSP behind the frpc_dev /
 * frpc_mem hooks (attach, a remotectl call through hexagonrpc(), INIT_MMAP with the method fallback, the
 * DSP going away), and apps_std over a temporary tree. sh phone/fastrpc/test.sh
 * Copyright (C) 2026 the ios-flame contributors. GPL-3.0-or-later (part of fastrpcd).
 */
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#include <libhexagonrpc/hexagonrpc.h>
#include <libhexagonrpc/interface/remotectl.h>
#include "../apps_std.h"
#include "../iobuffer.h"
#include "../listener.h"
#include "../localctl.h"
#include "../transport.h"

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

/* ---- 1. layout: 2 inputs (8 and 300 bytes), 1 output (16 bytes) at PA 0x8fe00f00 ---- */
static void test_layout(void)
{
	uint8_t in0[8] = { 1, 2, 3, 4, 5, 6, 7, 8 }, in1[300], out0[16];
	struct fastrpc_invoke_args a[3] = {
		{ (uint64_t)(uintptr_t)in0, sizeof(in0), -1, 0 },
		{ (uint64_t)(uintptr_t)in1, sizeof(in1), -1, 0 },
		{ (uint64_t)(uintptr_t)out0, sizeof(out0), -1, 0 },
	};
	uint32_t sc = REMOTE_SCALARS_MAKE(4, 2, 1);
	const uint64_t pa = 0x8fe00f00ull;	/* not page aligned on purpose: buffers straddle pages */
	uint8_t img[4096];
	struct frpc_layout lay;
	unsigned i;

	memset(in1, 0xa5, sizeof(in1));
	memset(img, 0xee, sizeof(img));
	CHECK(frpc_layout(sc, a, pa, 3, img, sizeof(img), &lay) == 0);
	/* metadata = 40 * 3 + 388 = 508; buffers at 512, 896 (512 + 8 -> 520 -> 640? no: 520 aligned to 128 = 640) */
	CHECK(lay.metalen == 508);
	CHECK(lay.off[0] == 512);	/* align128(508) */
	CHECK(lay.off[1] == 640);	/* align128(512 + 8) */
	CHECK(lay.off[2] == 1024);	/* align128(640 + 300 = 940) */
	CHECK(lay.used == 1040);
	/* remote_arg64[3] {pv, len} at 0 */
	CHECK(rd64(img + 0) == pa + 512 && rd64(img + 8) == 8);
	CHECK(rd64(img + 16) == pa + 640 && rd64(img + 24) == 300);
	CHECK(rd64(img + 32) == pa + 1024 && rd64(img + 40) == 16);
	/* smq_invoke_buf[3] {num, pgidx} at 48 */
	CHECK(rd32(img + 48) == 1 && rd32(img + 52) == 0);
	CHECK(rd32(img + 56) == 1 && rd32(img + 60) == 1);
	CHECK(rd32(img + 64) == 1 && rd32(img + 68) == 2);
	/* smq_phy_page[3] {addr, size} at 72: page of the bytes | 3 << 32, pages spanned * 4 KiB */
	CHECK(rd64(img + 72) == (0x8fe01000ull | 3ull << 32) && rd64(img + 80) == 4096);	/* 0x8fe01100..07 */
	CHECK(rd64(img + 88) == (0x8fe01000ull | 3ull << 32) && rd64(img + 96) == 4096);	/* 0x8fe01180..12ab */
	CHECK(rd64(img + 104) == (0x8fe01000ull | 3ull << 32) && rd64(img + 112) == 4096);	/* 0x8fe01300..0f */
	/* fdlist[16] + crclist[64] + early-wake hint: 120 .. 508, zero */
	for (i = 120; i < 508; i++)
		CHECK(img[i] == 0);
	/* the gap before each buffer is untouched/zero-free of input; inputs copied, the output zeroed */
	CHECK(memcmp(img + 512, in0, 8) == 0);
	CHECK(memcmp(img + 640, in1, 300) == 0);
	for (i = 1024; i < 1040; i++)
		CHECK(img[i] == 0);

	/* a buffer straddling a page boundary spans 2 pages */
	{
		uint8_t big[200];
		struct fastrpc_invoke_args b[1] = { { (uint64_t)(uintptr_t)big, sizeof(big), -1, 0 } };

		memset(big, 1, sizeof(big));
		CHECK(frpc_layout(REMOTE_SCALARS_MAKE(0, 1, 0), b, 0x1000ull - 512, 3, img, sizeof(img), &lay) == 0);
		/* metalen 428 -> offset 512 -> PA 0x1000 exactly: 1 page */
		CHECK(lay.off[0] == 512 && rd64(img + 16 + 8 + 0) == (0x1000ull | 3ull << 32) && rd64(img + 32) == 4096);
		CHECK(frpc_layout(REMOTE_SCALARS_MAKE(0, 1, 0), b, 0x1000ull - 512 - 128, 3, img, sizeof(img), &lay) == 0);
		/* bytes at 0xf80 .. 0x1047: 2 pages from 0 */
		CHECK(rd64(img + 24) == (0ull | 3ull << 32) && rd64(img + 32) == 8192);
	}
	/* empty buffers: num 0, no page, no space */
	{
		struct fastrpc_invoke_args e[2] = { { 0, 0, -1, 0 }, { (uint64_t)(uintptr_t)out0, 4, -1, 0 } };

		CHECK(frpc_layout(REMOTE_SCALARS_MAKE(1, 1, 1), e, 0x10000, 3, img, sizeof(img), &lay) == 0);
		CHECK(lay.metalen == 468 && rd32(img + 32) == 0 && rd64(img + 0) == 0 && rd64(img + 48) == 0);
		CHECK(lay.off[1] == 512 && lay.used == 516);
	}
	/* handles are refused, as is a buffer that does not fit */
	CHECK(frpc_layout(REMOTE_SCALARS_MAKEX(0, 1, 0, 0, 1, 0), a, pa, 3, img, sizeof(img), &lay) == -1);
	CHECK(frpc_layout(sc, a, pa, 3, img, 1000, &lay) == -1);
}

/* ---- 2. a fake DSP ---- */

#define RAM_BASE	0x80000000ull
#define RAM_SIZE	(48u << 20)

static uint8_t *ram;
static uint64_t ram_next = RAM_BASE;
static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_cond = PTHREAD_COND_INITIALIZER;
static uint8_t q[16][32];
static int q_len[16], q_head, q_tail, dsp_gone;
static struct frpc_msg last;
static int mmap_calls, mmap_fail_method = 4, n_allocs;

static int f_alloc(void *c, uint64_t size, uint64_t *pa)
{
	(void)c;
	if (ram_next + size > RAM_BASE + RAM_SIZE) {
		errno = ENOMEM;
		return -1;
	}
	*pa = ram_next;
	ram_next += size;
	n_allocs++;
	return 0;
}
static int f_wr(void *c, uint64_t pa, const void *b, size_t n) { (void)c; memcpy(ram + (pa - RAM_BASE), b, n); return 0; }
static int f_rd(void *c, uint64_t pa, void *b, size_t n) { (void)c; memcpy(b, ram + (pa - RAM_BASE), n); return 0; }

static void answer(uint64_t ctx, int32_t result, int v2, uint32_t flags)
{
	pthread_mutex_lock(&q_lock);
	memset(q[q_head % 16], 0, 32);
	memcpy(q[q_head % 16], &ctx, 8);
	memcpy(q[q_head % 16] + 8, &result, 4);
	if (v2) {
		memcpy(q[q_head % 16] + 12, &flags, 4);
		q[q_head % 16][20] = 2;	/* version */
	}
	q_len[q_head % 16] = v2 ? 32 : 16;
	q_head++;
	pthread_cond_broadcast(&q_cond);
	pthread_mutex_unlock(&q_lock);
}

/* The DSP side: read the metadata the way the DSP does (page addr from smq_phy_page + pv's page offset). */
static uint8_t *dsp_arg(const struct frpc_msg *m, unsigned i, uint64_t *len)
{
	unsigned n = REMOTE_SCALARS_INBUFS(m->sc) + REMOTE_SCALARS_OUTBUFS(m->sc);
	uint8_t *meta = ram + ((m->addr & 0xffffffffull) - RAM_BASE);
	uint64_t pv = rd64(meta + 16 * i), page = rd64(meta + 24 * n + 16 * i);

	*len = rd64(meta + 16 * i + 8);
	if (*len == 0)
		return NULL;
	CHECK(page >> 32 == 3);
	return ram + ((page & 0xffffffffull) - RAM_BASE) + (pv & 0xfff);
}

/* The DSP's listener: three requests (fopen "w", a 6000-byte fwrite that needs get_in_bufs2, then a
 * method nobody serves), checking each answer, then the DSP goes away. */
static uint8_t req[8192];
static uint32_t req_len, step, last_handle_out;
static int listener_done;

static size_t enc(uint8_t *at, size_t pos, const void *b, uint32_t n)
{
	memcpy(at + pos, &n, 4);
	pos += 4;
	if (pos & 7)
		pos += 8 - (pos & 7);
	memcpy(at + pos, b, n);
	return pos + n;
}

static void dsp_gone_now(void);

static void listener_call(const struct frpc_msg *m)
{
	int method = REMOTE_SCALARS_METHOD(m->sc);
	uint64_t len, olen;
	uint8_t *prim, *pout, *obuf;

	if (method == 3) {	/* init2 */
		answer(m->ctx, 0, 0, 0);
		return;
	}
	prim = dsp_arg(m, 0, &len);
	if (method == 5) {	/* get_in_bufs2(rctx, offset) -> the rest */
		uint32_t off = rd32(prim + 4);

		pout = dsp_arg(m, 1, &olen);
		obuf = dsp_arg(m, 2, &len);
		CHECK(rd32(prim) == 0x77 && off == 4096 && len >= req_len - off);
		memcpy(obuf, req + off, req_len - off);
		memcpy(pout, &req_len, 4);
		answer(m->ctx, 0, 0, 0);
		return;
	}
	/* next2(rctx, result, outbufs) -> rctx, handle, sc, inbufs_len, inbufs */
	{
		uint32_t rctx = rd32(prim), result = rd32(prim + 4), outlen = rd32(prim + 8), cap = rd32(prim + 12);
		uint64_t blen;
		uint8_t *ret = dsp_arg(m, 1, &blen);
		uint32_t pr[4];
		size_t pos = 0;
		uint32_t pi[2];

		pout = dsp_arg(m, 2, &olen);
		obuf = dsp_arg(m, 3, &len);
		CHECK(olen == 16 && len == cap && blen == outlen);
		switch (step++) {
		case 0:		/* first call: nothing to return */
			CHECK(rctx == 0 && result == 0xffffffff && outlen == 0);
			pi[0] = sizeof("/persist/sensors/registry/registry/big");
			pi[1] = 2;
			pos = enc(req, 0, pi, 8);
			pos = enc(req, pos, "/persist/sensors/registry/registry/big", pi[0]);
			pos = enc(req, pos, "w", 2);
			pr[0] = 0x76; pr[1] = 1; pr[2] = REMOTE_SCALARS_MAKE(0, 3, 1);
			break;
		case 1: {	/* fopen answered: [u32 4][pad][handle] */
			static uint8_t data[6000];

			CHECK(rctx == 0x76 && result == 0 && outlen == 12 && rd32(ret) == 4);
			last_handle_out = rd32(ret + 8);
			CHECK(last_handle_out != 0);
			memset(data, 'r', sizeof(data));
			pi[0] = last_handle_out;
			pi[1] = sizeof(data);
			pos = enc(req, 0, pi, 8);
			pos = enc(req, pos, data, sizeof(data));
			pr[0] = 0x77; pr[1] = 1; pr[2] = REMOTE_SCALARS_MAKE(5, 2, 1);
			break;
		}
		case 2:		/* fwrite answered: written 6000, eof 0 */
			CHECK(rctx == 0x77 && result == 0 && outlen == 16 && rd32(ret + 8) == 6000 && rd32(ret + 12) == 0);
			pi[0] = 1;
			pos = enc(req, 0, pi, 4);
			pr[0] = 0x78; pr[1] = 1; pr[2] = REMOTE_SCALARS_MAKE(7, 1, 0);	/* fsetpos: not served */
			break;
		default:	/* the unserved call answered with an error, no outputs; then the DSP dies */
			CHECK(rctx == 0x78 && result == 20 && outlen == 0);
			listener_done = 1;
			dsp_gone_now();
			return;
		}
		req_len = (uint32_t)pos;
		pr[3] = req_len;
		memcpy(pout, pr, 16);
		memcpy(obuf, req, req_len < cap ? req_len : cap);
		answer(m->ctx, 0, 0, 0);
	}
}

static int f_send(void *c, const struct frpc_msg *m)
{
	uint64_t len;
	uint8_t *p;

	(void)c;
	if (dsp_gone) {
		errno = ECONNRESET;
		return -1;
	}
	last = *m;
	CHECK(m->addr >> 32 == 3 && (m->addr & 0xfff) == 0 && m->size % 4096 == 0 && m->size >= 4096);
	if (m->handle == 1 && REMOTE_SCALARS_METHOD(m->sc) == 0) {	/* INIT_ATTACH(_SNS) */
		p = dsp_arg(m, 0, &len);
		CHECK(len == 4 && (int32_t)rd32(p) == 4242);
		answer(m->ctx, 0, 1, 0);
	} else if (m->handle == 1) {					/* INIT_MMAP */
		int method = REMOTE_SCALARS_METHOD(m->sc);

		mmap_calls++;
		p = dsp_arg(m, 0, &len);
		CHECK(len == 24 && rd32(p + 16) == (method == 2 ? 1u : 16u));
		p = dsp_arg(m, 1, &len);
		CHECK(len == 16 && rd64(p) >> 32 == 3 && rd64(p + 8) == 8192);
		p = dsp_arg(m, 2, &len);
		if (method == mmap_fail_method) {
			answer(m->ctx, 0x4e, 0, 0);
		} else {
			uint64_t v = 0xe0001000;

			memcpy(p, &v, 8);
			answer(m->ctx, 0, 0, 0);
		}
	} else if (m->handle == 0 && REMOTE_SCALARS_METHOD(m->sc) == 0) {	/* remotectl open */
		uint8_t *prim = dsp_arg(m, 0, &len), *name, *out;
		uint64_t nlen, olen;

		CHECK(len == 8);
		name = dsp_arg(m, 1, &nlen);
		CHECK(nlen == rd32(prim) && !strcmp((char *)name, "adsp_default_listener"));
		out = dsp_arg(m, 2, &olen);	/* prim out: handle, dlerr */
		CHECK(olen == 8);
		memcpy(out, &(uint32_t){ 0x55 }, 4);
		memset(out + 4, 0, 4);
		/* early response then completion: the result must be the early one */
		answer(m->ctx, 0, 1, 1);
		answer(m->ctx, 0, 1, 3);
	} else if (m->handle == 3) {						/* adsp_listener */
		listener_call(m);
	} else {
		answer(m->ctx, 20, 0, 0);
	}
	return 0;
}

static int f_recv(void *c, void *a, size_t cap)
{
	int n;

	(void)c;
	pthread_mutex_lock(&q_lock);
	while (q_head == q_tail && !dsp_gone)
		pthread_cond_wait(&q_cond, &q_lock);
	if (q_head == q_tail) {
		pthread_mutex_unlock(&q_lock);
		errno = ECONNRESET;
		return -1;
	}
	n = q_len[q_tail % 16] < (int)cap ? q_len[q_tail % 16] : (int)cap;
	memcpy(a, q[q_tail % 16], n);
	q_tail++;
	pthread_mutex_unlock(&q_lock);
	return n;
}

static void dsp_gone_now(void)
{
	pthread_mutex_lock(&q_lock);
	dsp_gone = 1;
	pthread_cond_broadcast(&q_cond);
	pthread_mutex_unlock(&q_lock);
}

static void test_transport(void)
{
	struct frpc_dev dev = { f_send, f_recv, NULL };
	struct frpc_mem mem = { f_alloc, f_wr, f_rd, NULL };
	struct fastrpc_req_mmap mm = { -1, 0x1000, 0, 8000, 0 };
	uint32_t hdl = 0, dlerr = 7;
	char err[16];
	int fd, ret;

	ram = calloc(1, RAM_SIZE);
	CHECK(frpc_start(&dev, &mem) == 0);
	fd = frpc_session_new(4242);
	CHECK(fd >= 0);

	CHECK(fastrpc_ioctl(fd, FASTRPC_IOCTL_INIT_ATTACH_SNS, NULL) == 0);
	CHECK(last.client == 0 && last.handle == 1 && last.sc == REMOTE_SCALARS_MAKE(0, 1, 0));
	CHECK((last.ctx & 0xf) == 2 && (last.ctx >> 4) != 0);
	CHECK(last.size == 4096);

	ret = remotectl_open(fd, sizeof("adsp_default_listener"), "adsp_default_listener", &hdl, sizeof(err), err, &dlerr);
	CHECK(ret == 0 && hdl == 0x55 && dlerr == 0);
	CHECK(last.client == 4242 && last.handle == 0 && last.sc == REMOTE_SCALARS_MAKE(0, 2, 2));

	/* INIT_MMAP: method 4 refused -> method 2 used from then on */
	frpc_mmap_method = 4;
	CHECK(fastrpc_ioctl(fd, FASTRPC_IOCTL_MMAP, &mm) == 0);
	CHECK(mm.vaddrout == 0xe0001000 && mmap_calls == 2 && frpc_mmap_method == 2);
	CHECK(last.client == 0 && last.sc == REMOTE_SCALARS_MAKE(2, 2, 1));
	mmap_calls = 0;
	CHECK(fastrpc_ioctl(fd, FASTRPC_IOCTL_MMAP, &mm) == 0 && mmap_calls == 1);

	/* unknown call: the DSP's error comes back as the result */
	{
		struct fastrpc_invoke inv = { 9, REMOTE_SCALARS_MAKE(3, 0, 0), 0 };

		CHECK(fastrpc_ioctl(fd, FASTRPC_IOCTL_INVOKE, &inv) == 20);
	}
	/* buffers are reused: a dozen calls do not allocate more */
	{
		int before = n_allocs, i;

		for (i = 0; i < 12; i++)
			CHECK(remotectl_open(fd, sizeof("adsp_default_listener"), "adsp_default_listener", &hdl,
					     sizeof(err), err, &dlerr) == 0);
		CHECK(n_allocs == before);
	}

	/* the DSP goes away: calls fail with ECONNRESET and frpc_dead() says so */
	pthread_mutex_lock(&q_lock);
	dsp_gone = 1;
	pthread_cond_broadcast(&q_cond);
	pthread_mutex_unlock(&q_lock);
	usleep(100000);
	CHECK(frpc_dead());
	errno = 0;
	CHECK(fastrpc_ioctl(fd, FASTRPC_IOCTL_INIT_ATTACH_SNS, NULL) == -1 && errno == ECONNRESET);
	frpc_stop();
	free(ram);
}

/* ---- 3. apps_std over a temporary tree ---- */

static char root[256];

static void put_file(const char *rel, const char *content)
{
	char p[512];
	FILE *f;

	snprintf(p, sizeof(p), "%s/%s", root, rel);
	f = fopen(p, "w");
	fputs(content, f);
	fclose(f);
}

static void mk(const char *rel)
{
	char p[512];

	snprintf(p, sizeof(p), "%s/%s", root, rel);
	mkdir(p, 0755);
}

/* Call method m of the interface with a prim-in blob, string inputs and output buffer sizes. */
static uint32_t call(struct fastrpc_interface *i, unsigned m, struct fastrpc_io_buffer *in, struct fastrpc_io_buffer *out)
{
	return i->procs[m].impl(i->data, in, out);
}

static struct fastrpc_io_buffer B(const void *p, size_t s)
{
	struct fastrpc_io_buffer b = { s, (void *)p };
	return b;
}

static void test_apps_std(void)
{
	char host[1024], buf[512];
	struct fastrpc_interface *as;
	uint32_t prim[4], h = 0, hw = 0, oprim[2];
	uint64_t dh = 0;
	struct {
		uint32_t ino;
		char name[256];
		uint32_t eof;
	} de;
	uint8_t st[96];
	struct fastrpc_io_buffer in[5], out[2];
	int seen_cfg = 0, n;

	snprintf(root, sizeof(root), "%s/fastrpcd-test-%d", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
	mkdir(root, 0755);
	mk("vendor"); mk("vendor/etc"); mk("vendor/etc/sensors"); mk("vendor/etc/sensors/config");
	mk("persist"); mk("persist/sensors"); mk("persist/sensors/registry"); mk("persist/sensors/registry/registry");
	mk("sys"); mk("sys/devices"); mk("sys/devices/soc0");
	mk("usr"); mk("usr/lib"); mk("usr/lib/qcom"); mk("usr/lib/qcom/adsp");
	put_file("vendor/etc/sensors/config/lito_lsm6dsr_0.json", "{\"config\":1}\n");
	put_file("vendor/etc/sensors/sns_reg_config", "reg\n");
	put_file("sys/devices/soc0/soc_id", "434\n");
	put_file("usr/lib/qcom/adsp/libfoo.so", "ELF");
	put_file("../fastrpcd-secret", "no");

	/* mapping */
	CHECK(apps_std_map(root, "/vendor/etc/sensors/sns_reg_config", 0, host, sizeof(host)) == 0);
	CHECK(strstr(host, "/vendor/etc/sensors/sns_reg_config") != NULL);
	CHECK(apps_std_map(root, "/system/vendor/etc/sensors/sns_reg_config", 0, host, sizeof(host)) == 0);
	CHECK(apps_std_map(root, "/mnt/vendor/persist/sensors/registry/registry/x", 1, host, sizeof(host)) == 0);
	CHECK(strstr(host, "/persist/sensors/registry/registry/x") != NULL);
	CHECK(apps_std_map(root, "/vendor/../../etc/passwd", 0, host, sizeof(host)) == -1);
	CHECK(apps_std_map(root, "/../fastrpcd-secret", 0, host, sizeof(host)) == -1);
	CHECK(apps_std_map(root, "vendor/etc", 0, host, sizeof(host)) == -1);
	CHECK(apps_std_map(root, "/vendor/etc/sensors/sns_reg_config", 1, host, sizeof(host)) == -1);	/* read-only */
	CHECK(apps_std_map(root, "/vendor/./etc/../etc/sensors", 0, host, sizeof(host)) == 0);
	{	/* a link out of the tree is refused */
		char l[512];

		snprintf(l, sizeof(l), "%s/vendor/etc/escape", root);
		CHECK(symlink("/etc", l) == 0);
		CHECK(apps_std_map(root, "/vendor/etc/escape/passwd", 0, host, sizeof(host)) == -1);
	}

	as = fastrpc_apps_std_init(root);
	CHECK(as != NULL && as->n_procs == 34);

	/* fopen_with_env($ADSP_LIBRARY_PATH, absolute name) + fread + fclose */
	prim[0] = sizeof("ADSP_LIBRARY_PATH");
	in[0] = B(prim, 16);
	in[1] = B("ADSP_LIBRARY_PATH", sizeof("ADSP_LIBRARY_PATH"));
	in[2] = B(";", 2);
	in[3] = B("/vendor/etc/sensors/config/lito_lsm6dsr_0.json", sizeof("/vendor/etc/sensors/config/lito_lsm6dsr_0.json"));
	in[4] = B("r", 2);
	out[0] = B(&h, 4);
	CHECK(call(as, 19, in, out) == 0 && h != 0);
	prim[0] = h;
	prim[1] = sizeof(buf);
	in[0] = B(prim, 8);
	out[0] = B(oprim, 8);
	out[1] = B(buf, sizeof(buf));
	memset(buf, 0, sizeof(buf));
	CHECK(call(as, 4, in, out) == 0 && oprim[0] == 13 && oprim[1] == 1 && !memcmp(buf, "{\"config\":1}\n", 13));
	in[0] = B(&h, 4);
	CHECK(call(as, 3, in, out) == 0);
	CHECK(call(as, 3, in, out) != 0);	/* closed twice */

	/* relative name through the search path */
	in[0] = B(prim, 16);
	in[3] = B("libfoo.so", sizeof("libfoo.so"));
	out[0] = B(&h, 4);
	CHECK(call(as, 19, in, out) == 0 && h != 0);
	/* missing file: ENOENT, no handle */
	in[3] = B("/vendor/etc/sensors/config/nope.json", sizeof("/vendor/etc/sensors/config/nope.json"));
	CHECK(call(as, 19, in, out) == ENOENT);
	/* write outside persist: refused */
	in[3] = B("/vendor/etc/sensors/sns_reg_config", sizeof("/vendor/etc/sensors/sns_reg_config"));
	in[4] = B("w", 2);
	CHECK(call(as, 19, in, out) == EACCES);

	/* registry write (fopen "w" + fwrite of more than 256 bytes) and read back */
	in[0] = B(prim, 8);
	in[1] = B("/mnt/vendor/persist/sensors/registry/registry/lsm6dsr_0", sizeof("/mnt/vendor/persist/sensors/registry/registry/lsm6dsr_0"));
	in[2] = B("w", 2);
	out[0] = B(&hw, 4);
	CHECK(call(as, 0, in, out) == 0 && hw != 0);
	memset(buf, 'x', 400);
	prim[0] = hw;
	prim[1] = 400;
	in[0] = B(prim, 8);
	in[1] = B(buf, 400);
	out[0] = B(oprim, 8);
	CHECK(call(as, 5, in, out) == 0 && oprim[0] == 400);
	in[0] = B(&hw, 4);
	CHECK(call(as, 3, in, out) == 0);
	{
		char p[512];
		struct stat s;

		snprintf(p, sizeof(p), "%s/persist/sensors/registry/registry/lsm6dsr_0", root);
		CHECK(stat(p, &s) == 0 && s.st_size == 400);
	}

	/* stat (extended method 31: prim = method id, name length) */
	prim[0] = 31;
	prim[1] = sizeof("/sys/devices/soc0/soc_id");
	in[0] = B(prim, 8);
	in[1] = B("/sys/devices/soc0/soc_id", sizeof("/sys/devices/soc0/soc_id"));
	out[0] = B(st, sizeof(st));
	CHECK(call(as, 31, in, out) == 0 && rd64(st + 40) == 4);
	in[1] = B("/sys/devices/soc0/nope", sizeof("/sys/devices/soc0/nope"));
	CHECK(call(as, 31, in, out) == ENOENT);

	/* opendir / readdir / closedir */
	prim[0] = sizeof("/vendor/etc/sensors/config");
	in[0] = B(prim, 4);
	in[1] = B("/vendor/etc/sensors/config", sizeof("/vendor/etc/sensors/config"));
	out[0] = B(&dh, 8);
	CHECK(call(as, 26, in, out) == 0 && dh != 0);
	in[0] = B(&dh, 8);
	out[0] = B(&de, sizeof(de));
	for (n = 0; n < 10; n++) {
		CHECK(call(as, 28, in, out) == 0);
		if (de.eof)
			break;
		if (!strcmp(de.name, "lito_lsm6dsr_0.json"))
			seen_cfg = 1;
	}
	CHECK(seen_cfg && de.eof && sizeof(de) == 264);
	CHECK(call(as, 27, in, out) == 0);
	/* opendir of an escape */
	in[0] = B(prim, 4);
	in[1] = B("/../..", sizeof("/../.."));
	out[0] = B(&dh, 8);
	CHECK(call(as, 26, in, out) != 0);

	/* readdir order: tcs3701*, lsm6dsr*, sns_* first, then by name */
	{
		static const char *names[] = { "bmp380_0", "sns_cm", "tcs3701_0.prox", "lsm6dsr_0", "abc", "tcs3701_0", "sns_amd" };
		static const char *want[] = { "tcs3701_0", "tcs3701_0.prox", "lsm6dsr_0", "sns_amd", "sns_cm", "abc", "bmp380_0" };
		char rel[256];
		unsigned k;

		for (k = 0; k < 7; k++) {
			snprintf(rel, sizeof(rel), "persist/sensors/registry/registry/%s", names[k]);
			put_file(rel, "{}");
		}
		prim[0] = sizeof("/persist/sensors/registry/registry");
		in[0] = B(prim, 4);
		in[1] = B("/persist/sensors/registry/registry", sizeof("/persist/sensors/registry/registry"));
		out[0] = B(&dh, 8);
		CHECK(call(as, 26, in, out) == 0);
		in[0] = B(&dh, 8);
		out[0] = B(&de, sizeof(de));
		for (k = 0, n = 0; n < 12; n++) {
			CHECK(call(as, 28, in, out) == 0);
			if (de.eof)
				break;
			CHECK(k < 7 && !strcmp(de.name, want[k]));	/* exactly this order, nothing else */
			k++;
		}
		CHECK(k == 7 && de.eof);
		CHECK(call(as, 27, in, out) == 0);
	}

	/* mkdir under persist, refused elsewhere */
	prim[0] = sizeof("/persist/sensors/registry/new");
	prim[1] = 0755;
	in[0] = B(prim, 8);
	in[1] = B("/persist/sensors/registry/new", sizeof("/persist/sensors/registry/new"));
	CHECK(call(as, 29, in, out) == 0);
	in[1] = B("/vendor/new", sizeof("/vendor/new"));
	CHECK(call(as, 29, in, out) == EACCES);

	fastrpc_apps_std_deinit(as);
	{
		char cmd[1100];

		snprintf(cmd, sizeof(cmd), "rm -rf '%s' '%s/../fastrpcd-secret'", root, root);
		if (system(cmd)) {}
	}
}

static void test_listener(void)
{
	struct frpc_dev dev = { f_send, f_recv, NULL };
	struct frpc_mem mem = { f_alloc, f_wr, f_rd, NULL };
	struct fastrpc_interface *ifaces[3];
	char p[512];
	struct stat st;
	int fd, ret;

	ram = calloc(1, RAM_SIZE);
	ram_next = RAM_BASE;
	dsp_gone = 0;
	q_head = q_tail = 0;
	snprintf(root, sizeof(root), "%s/fastrpcd-ltest-%d", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
	mkdir(root, 0755);
	mk("persist"); mk("persist/sensors"); mk("persist/sensors/registry"); mk("persist/sensors/registry/registry");
	CHECK(frpc_start(&dev, &mem) == 0);
	fd = frpc_session_new(4242);
	ifaces[0] = fastrpc_localctl_init(3, ifaces);
	ifaces[1] = fastrpc_apps_std_init(root);
	ifaces[2] = NULL;
	CHECK(ifaces[0] && ifaces[1]);
	ret = run_fastrpc_listener(fd, 2, ifaces);
	CHECK(ret != 0 && listener_done && frpc_dead());
	snprintf(p, sizeof(p), "%s/persist/sensors/registry/registry/big", root);
	CHECK(stat(p, &st) == 0 && st.st_size == 6000);
	frpc_stop();
	fastrpc_localctl_deinit(ifaces[0]);
	fastrpc_apps_std_deinit(ifaces[1]);
	{
		char cmd[1100];

		snprintf(cmd, sizeof(cmd), "rm -rf '%s'", root);
		if (system(cmd)) {}
	}
	free(ram);
}

int main(void)
{
	test_layout();
	test_transport();
	test_apps_std();
	test_listener();
	if (failures) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("fastrpcd host tests: all passed\n");
	return 0;
}
