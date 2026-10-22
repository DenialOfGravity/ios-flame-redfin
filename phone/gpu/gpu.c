/*
 * Userland layer over the kernel's A640 core (sweet_a6xx.c): /dev/pmem
 * hooks, persistent state, buffers, captures, replay, tests and dumps.
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "gpu.h"
#include "pmem.h"

struct gpu_state st;

#define STATE_MAGIC	0x47505530	/* "GPU0" */
#define STATE_VERSION	3

/* ---- logging ---- */

static int console_fd = -2;

static void vglog(const char *fmt, va_list ap)
{
	char buf[512];
	int n = vsnprintf(buf, sizeof(buf), fmt, ap);
	if (n < 0)
		return;
	if (n >= (int)sizeof(buf))
		n = sizeof(buf) - 1;
	fputs(buf, stdout);
	fflush(stdout);
	if (console_fd == -2)
		console_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (console_fd >= 0) {
		write(console_fd, "GPU: ", 5);
		write(console_fd, buf, (size_t)n);
	}
}

void glog(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vglog(fmt, ap);
	va_end(ap);
}

/* ---- the core's environment: /dev/pmem ---- */

uint32_t a6_rd(uint64_t pa) { return rd32(pa); }
void a6_wr(uint64_t pa, uint32_t v) { wr32(pa, v); }
int a6_write(uint64_t pa, const void *buf, size_t len) { return pm_wr(pa, buf, len); }
int a6_read(uint64_t pa, void *buf, size_t len) { return pm_rd(pa, buf, len); }
void a6_delay_ms(unsigned ms) { delay_ms(ms); }
void a6_delay_us(unsigned us) { usleep(us); }
void a6_smc(uint64_t x[8]) { pm_smc(x); }

void a6_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vglog(fmt, ap);
	va_end(ap);
}

/* Firmware from /var/local/gpu/fw, kept for the life of the process. */
uint64_t a6_pt_extra(uint32_t n)
{
	(void)n;
	return 0;	/* the pool's arena only */
}

const uint8_t *a6_firmware(const char *name, uint32_t *len)
{
	static struct { char name[32]; uint8_t *data; uint32_t len; } cache[8];
	for (int i = 0; i < 8; i++)
		if (cache[i].data && !strcmp(cache[i].name, name)) {
			*len = cache[i].len;
			return cache[i].data;
		}
	char path[256];
	snprintf(path, sizeof(path), "%s/%s", GPU_FW_DIR, name);
	FILE *f = fopen(path, "rb");
	if (!f) {
		glog("fw: %s: %s\n", path, strerror(errno));
		return NULL;
	}
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *buf = calloc(1, (size_t)sz + 4);
	if (!buf || fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
		fclose(f);
		free(buf);
		return NULL;
	}
	fclose(f);
	for (int i = 0; i < 8; i++)
		if (!cache[i].data) {
			snprintf(cache[i].name, sizeof(cache[i].name), "%s", name);
			cache[i].data = buf;
			cache[i].len = (uint32_t)sz;
			break;
		}
	*len = (uint32_t)sz;
	return buf;
}

/* ---- state ---- */

void gpu_save(void)
{
	mkdir(GPU_DIR, 0755);
	int fd = open(GPU_STATE_PATH ".tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0 || write(fd, &st, sizeof(st)) != (ssize_t)sizeof(st)) {
		fprintf(stderr, "gpu: cannot write %s: %s\n", GPU_STATE_PATH, strerror(errno));
		if (fd >= 0)
			close(fd);
		return;
	}
	fsync(fd);
	close(fd);
	rename(GPU_STATE_PATH ".tmp", GPU_STATE_PATH);
}

/* 0: state loaded, pool alive and the CP running our SQE. */
int gpu_attach(void)
{
	pm_init();
	int fd = open(GPU_STATE_PATH, O_RDONLY);
	if (fd < 0)
		return -1;
	ssize_t n = read(fd, &st, sizeof(st));
	close(fd);
	if (n != (ssize_t)sizeof(st) || st.magic != STATE_MAGIC || st.version != STATE_VERSION)
		return -1;
	struct pmem_list l;
	int alive = 0;
	if (pm_list(&l) == 0)
		for (uint32_t i = 0; i < l.count; i++)
			if (l.ent[i].pa == st.hw.pool_pa && l.ent[i].size >= A6_POOL_SIZE)
				alive = 1;
	if (!alive)
		return -2;	/* stale: from an earlier boot */
	if (!a6_gx_up())
		return -3;
	if (!a6_cp_running(&st.hw))
		return -4;
	return 0;
}

int gpu_clear_fault(void)
{
	return a6_clear_fault(&st.hw);
}

/* ---- buffers ---- */

static void zero_pa(uint64_t pa, uint64_t size)
{
	static uint8_t z[0x10000];
	for (uint64_t o = 0; o < size; o += sizeof(z))
		pm_wr(pa + o, z, size - o < sizeof(z) ? size - o : sizeof(z));
}

struct gpu_bo *bo_get(const char *name)
{
	for (uint32_t i = 0; i < st.nbo; i++)
		if (!strncmp(st.bo[i].name, name, sizeof(st.bo[i].name)))
			return &st.bo[i];
	return NULL;
}

struct gpu_bo *bo_new(const char *name, uint64_t size)
{
	struct gpu_bo *b = bo_get(name);
	size = (size + 0xfff) & ~0xfffull;
	if (b && b->size >= size)
		return b;
	if (st.nbo >= MAX_BOS || st.heap_next + size > A6_POOL_SIZE) {
		glog("bo %s: out of space (%u bos, heap at %llx)\n", name, st.nbo,
		     (unsigned long long)st.heap_next);
		return NULL;
	}
	if (!b) {
		b = &st.bo[st.nbo++];
		memset(b, 0, sizeof(*b));
		strncpy(b->name, name, sizeof(b->name) - 1);
	}
	b->off = st.heap_next;		/* a grown bo moves; the old space is lost */
	b->size = size;
	st.heap_next += size;
	zero_pa(bo_pa(b), size);
	gpu_save();
	return b;
}

/* ---- .rd capture (Mesa src/freedreno/common/redump.h) ---- */

enum { RD_GPUADDR = 3, RD_CMDSTREAM_ADDR = 6, RD_BUFFER_CONTENTS = 12, RD_GPU_ID = 13, RD_CHIP_ID = 14 };

static void rd_sect(FILE *f, uint32_t type, const void *buf, uint32_t size)
{
	fwrite(&type, 4, 1, f);
	fwrite(&size, 4, 1, f);
	fwrite(buf, 1, size, f);
}

static void rd_buffer(FILE *f, uint64_t va, uint64_t pa, uint32_t size)
{
	uint32_t a[3] = { (uint32_t)va, size, (uint32_t)(va >> 32) };
	rd_sect(f, RD_GPUADDR, a, sizeof(a));
	uint8_t *buf = malloc(size);
	if (buf && !pm_rd(pa, buf, size))
		rd_sect(f, RD_BUFFER_CONTENTS, buf, size);
	free(buf);
}

/* Every bo, the scratch page and replayed buffers, then the IB as the command stream. */
static void rd_write(const char *path, uint64_t ib_va, uint32_t dwords)
{
	FILE *f = fopen(path, "wb");
	if (!f) {
		glog("rd: %s: %s\n", path, strerror(errno));
		return;
	}
	uint32_t id = A6_GPU_ID;
	uint64_t chip = A6_CHIP_ID;
	rd_sect(f, RD_GPU_ID, &id, 4);
	rd_sect(f, RD_CHIP_ID, &chip, 8);
	rd_buffer(f, pool_va(A6_OFF_SCRATCH), pool_pa(A6_OFF_SCRATCH), 0x1000);
	for (uint32_t i = 0; i < st.nbo; i++)
		rd_buffer(f, bo_va(&st.bo[i]), bo_pa(&st.bo[i]), (uint32_t)st.bo[i].size);
	for (uint32_t i = 0; i < st.nrep; i++)
		rd_buffer(f, st.rep[i].iova, st.rep[i].pa, (uint32_t)st.rep[i].size);
	uint32_t c[3] = { (uint32_t)ib_va, dwords, (uint32_t)(ib_va >> 32) };
	rd_sect(f, RD_CMDSTREAM_ADDR, c, sizeof(c));
	fclose(f);
}

/* ---- submission ---- */

int gpu_submit(uint64_t ib_va, uint32_t dwords, unsigned timeout_ms, const char *rd)
{
	if (rd)
		rd_write(rd, ib_va, dwords);
	st.submits++;
	struct timespec t0, t1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	int rc = a6_submit_ib(&st.hw, ib_va, dwords, timeout_ms);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	if (getenv("GPU_TIME"))
		glog("submit %u: %.3f ms on the GPU (submit to fence)\n", st.submits,
		     (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
	gpu_save();
	if (rc)
		glog("submit %u: fence %u, memory has %u: HANG or fault (gpu dump)\n", st.submits, st.hw.fence,
		     a6_fence_read(&st.hw));
	return rc;
}

int gpu_submit_dwords(const uint32_t *dw, uint32_t n, unsigned timeout_ms, const char *rd)
{
	struct gpu_bo *ib = bo_new("ib", 4ull * n);
	if (!ib)
		return -1;
	pm_wr(bo_pa(ib), dw, 4ull * n);
	return gpu_submit(bo_va(ib), n, timeout_ms, rd);
}

/* ---- panel ---- */

#define MDP		0x0ae00000ull
#define SSPP_VIG(n)	(MDP + 0x5000 + 0x2000ull * (n))
#define SSPP_YSTRIDE0	0x24
#define CTL0_FLUSH	(MDP + 0x2000 + 0x18)

/* ABL drives the panel through VIG0 + VIG1 (540 columns each) from 0x9c400000; autorefresh picks this up. */
void panel_stride(uint32_t stride)
{
	wr32(SSPP_VIG(0) + SSPP_YSTRIDE0, stride);
	wr32(SSPP_VIG(1) + SSPP_YSTRIDE0, stride);
	wr32(CTL0_FLUSH, 0x3);
	glog("panel: stride %u (vig0 %x vig1 %x)\n", stride, rd32(SSPP_VIG(0) + SSPP_YSTRIDE0),
	     rd32(SSPP_VIG(1) + SSPP_YSTRIDE0));
}

/* ---- tests ---- */

static void replay_reset(void);
static int replay_buffer(uint64_t iova, uint32_t size);

/* A big test buffer: its own allocation, mapped at iova (like replayed buffers). */
static int big_buffer(uint64_t iova, uint32_t size, uint64_t *pa)
{
	int i = replay_buffer(iova, size);
	if (i < 0)
		return -1;
	*pa = st.rep[i].pa;
	return 0;
}


static int test_memwrite(void)
{
	uint64_t pa = pool_pa(A6_OFF_SCRATCH) + 0x100, va = pool_va(A6_OFF_SCRATCH) + 0x100;
	wr32(pa, 0x11111111);
	uint32_t dw[] = { a6_pkt7(A6_CP_MEM_WRITE, 3), (uint32_t)va, (uint32_t)(va >> 32), 0xcafef00d };
	int rc = gpu_submit_dwords(dw, 4, 1000, GPU_DIR "/memwrite.rd");
	glog("gpu: target memory = %x %s\n", rd32(pa),
	     rd32(pa) == 0xcafef00d ? "*** GPU EXECUTED OUR COMMANDS ***" : "(unchanged)");
	return rc || rd32(pa) != 0xcafef00d ? -1 : 0;
}

static uint32_t band_px(uint32_t x)
{
	uint32_t r = x * 255 / (FB_W - 1), b = 255 - r, g = (x / 60) % 2 ? 200 : 40;
	return 0xff000000 | (r << 16) | (g << 8) | b;
}

/* gpuprobe.c's band at GPU VA base: one gradient row by CP_MEM_WRITE, CP_MEMCPY for the rest. */
static int paint_band(uint64_t base, uint32_t h, uint32_t stride, const char *rd)
{
	uint32_t n = 0, *dw = malloc(4 * (4 + FB_W + 6 * h));
	dw[n++] = a6_pkt7(A6_CP_MEM_WRITE, 2 + FB_W);
	dw[n++] = (uint32_t)base;
	dw[n++] = (uint32_t)(base >> 32);
	for (uint32_t x = 0; x < FB_W; x++)
		dw[n++] = band_px(x);
	dw[n++] = a6_pkt7(A6_CP_WAIT_FOR_IDLE, 0);
	for (uint32_t y = 1; y < h; y++) {
		uint64_t dst = base + (uint64_t)y * stride;
		dw[n++] = a6_pkt7(A6_CP_MEMCPY, 5);
		dw[n++] = FB_W;
		dw[n++] = (uint32_t)base;
		dw[n++] = (uint32_t)(base >> 32);
		dw[n++] = (uint32_t)dst;
		dw[n++] = (uint32_t)(dst >> 32);
	}
	int rc = gpu_submit_dwords(dw, n, 2000, rd);
	free(dw);
	return rc;
}

/* Checked into a buffer (the panel is redrawn by the kernel), then on the panel to look at. */
static int test_paint(void)
{
	const uint32_t h = 600;
	struct gpu_bo *b = bo_new("paint", (uint64_t)FB_STRIDE * h);
	if (!b || paint_band(bo_va(b), h, FB_STRIDE, GPU_DIR "/paint.rd"))
		return -1;
	uint32_t *px = malloc(FB_STRIDE * h), bad = 0;
	pm_rd(bo_pa(b), px, (size_t)FB_STRIDE * h);
	for (uint32_t y = 0; y < h; y++)
		for (uint32_t x = 0; x < FB_W; x++)
			if (px[y * (FB_STRIDE / 4) + x] != band_px(x) && bad++ < 3)
				glog("paint: (%u,%u) = %08x, want %08x\n", x, y, px[y * (FB_STRIDE / 4) + x], band_px(x));
	free(px);
	glog("gpu: painted %ux%u into bo paint: %u wrong pixels%s\n", FB_W, h, bad, bad ? "" : " (exact)");
	int rc = paint_band(A6_GVA_FB + 700ull * FB_STRIDE, h, FB_STRIDE, NULL);
	glog("gpu: painted the panel at y 700 -> %d\n", rc);
	return bad ? -1 : rc;
}

/* The iOS-sized test frame of work/mesa/vkblit.c: gradients, a 75-px grid, white border, red square. */
#define SRC_W		1125
#define SRC_H		2436
#define SRC_PITCH	4608

static uint32_t pattern(uint32_t x, uint32_t y)
{
	uint32_t r = x * 255 / (SRC_W - 1), g = y * 255 / (SRC_H - 1), b = 128;
	if (x % 75 < 3 || y % 75 < 3)
		r = g = b = 0;
	if (x < 6 || y < 6 || x >= SRC_W - 6 || y >= SRC_H - 6)
		r = g = b = 255;
	if (x >= 100 && x < 300 && y >= 100 && y < 300)
		r = 255, g = b = 0;
	return 0xff000000u | (r << 16) | (g << 8) | b;
}

#define SRC_IOVA	0x100000000ull
#define DST_IOVA	0x101000000ull

/* The pattern at SRC_IOVA; returns its PA (0 on failure). */
static uint64_t pattern_buffer(void)
{
	uint64_t pa;
	replay_reset();
	if (big_buffer(SRC_IOVA, SRC_PITCH * SRC_H, &pa))
		return 0;
	uint32_t *row = calloc(1, SRC_PITCH);
	for (uint32_t y = 0; y < SRC_H; y++) {
		for (uint32_t x = 0; x < SRC_W; x++)
			row[x] = pattern(x, y);
		pm_wr(pa + (uint64_t)y * SRC_PITCH, row, SRC_PITCH);
	}
	free(row);
	return pa;
}

/* The fitted blit: 1125x2436 -> 1053x2280 at x 13 (aspect kept), bilinear. */
static void fit_blit(struct a6_blit *b, uint64_t src, uint64_t dst, uint32_t dst_pitch)
{
	memset(b, 0, sizeof(*b));
	b->src_iova = src;
	b->src_w = SRC_W;
	b->src_h = SRC_H;
	b->src_pitch = SRC_PITCH;
	b->sw = SRC_W;
	b->sh = SRC_H;
	b->dst_iova = dst;
	b->dst_pitch = dst_pitch;
	b->dh = FB_H;
	b->dw = (SRC_W * FB_H + SRC_H / 2) / SRC_H;	/* 1053 */
	b->dx = (FB_W - b->dw) / 2;
	b->filter = true;
}

static double ref_px(const struct a6_blit *b, uint32_t dx, uint32_t dy, int c)
{
	double u = (dx - b->dx + 0.5) * b->sw / b->dw - 0.5, v = (dy - b->dy + 0.5) * b->sh / b->dh - 0.5;
	int x0 = (int)floor(u), y0 = (int)floor(v);
	double fx = u - x0, fy = v - y0, s = 0;
	for (int j = 0; j < 2; j++)
		for (int i = 0; i < 2; i++) {
			int x = x0 + i < 0 ? 0 : x0 + i >= SRC_W ? SRC_W - 1 : x0 + i;
			int y = y0 + j < 0 ? 0 : y0 + j >= SRC_H ? SRC_H - 1 : y0 + j;
			double w = (i ? fx : 1 - fx) * (j ? fy : 1 - fy);
			s += w * ((pattern((uint32_t)x, (uint32_t)y) >> (8 * c)) & 0xff);
		}
	return s;
}

/* Our own blit stream (a6_blit_ib) into a buffer, checked against a bilinear reference. */
static int test_blit(void)
{
	struct gpu_bo *ib = bo_new("blitib", 4096);
	uint64_t dpa;
	if (!ib || !pattern_buffer() || big_buffer(DST_IOVA, FB_STRIDE_GPU * FB_H, &dpa))
		return -1;
	a6_tlb_flush(&st.hw);
	uint8_t *fill = malloc(FB_STRIDE_GPU);
	memset(fill, 0x5a, FB_STRIDE_GPU);
	for (uint32_t y = 0; y < FB_H; y++)
		pm_wr(dpa + (uint64_t)y * FB_STRIDE_GPU, fill, FB_STRIDE_GPU);
	free(fill);
	struct a6_blit b;
	fit_blit(&b, SRC_IOVA, DST_IOVA, FB_STRIDE_GPU);
	uint32_t dw[A6_BLIT_MAX_DW], n = a6_blit_ib(&st.hw, &b, dw);
	pm_wr(bo_pa(ib), dw, 4ull * n);
	struct timespec t0, t1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	int rc = gpu_submit(bo_va(ib), n, 1000, NULL);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	if (getenv("GPU_RD"))
		rd_write(getenv("GPU_RD"), bo_va(ib), n);
	glog("blit: %u dwords, submit+wait %.2f ms -> %d\n", n,
	     (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6, rc);
	if (rc)
		return rc;
	uint8_t *px = malloc((size_t)FB_STRIDE_GPU * FB_H);
	pm_rd(dpa, px, (size_t)FB_STRIDE_GPU * FB_H);
	double worst = 0;
	uint32_t over = 0, side = 0;
	srand(1);
	for (int k = 0; k < 20000; k++) {
		uint32_t x = b.dx + (uint32_t)rand() % b.dw, y = (uint32_t)rand() % FB_H;
		for (int c = 0; c < 3; c++) {
			double e = fabs(px[(size_t)y * FB_STRIDE_GPU + 4 * x + c] - ref_px(&b, x, y, c));
			worst = e > worst ? e : worst;
			over += e > 2;
		}
	}
	for (uint32_t y = 0; y < FB_H; y += 97)
		for (uint32_t x = 0; x < FB_W; x++)
			if ((x < b.dx || x >= b.dx + b.dw) && px[(size_t)y * FB_STRIDE_GPU + 4 * x] != 0x5a)
				side++;
	free(px);
	glog("blit: 60000 channel values vs bilinear reference: worst %.1f, %u over 2; side bars %s\n", worst,
	     over, side ? "WRITTEN" : "untouched");
	return over || side ? -1 : 0;
}

/* The fitted blit onto the panel: stride 4352, bars cleared by the CPU. */
static int test_fb(void)
{
	struct gpu_bo *ib = bo_new("blitib", 4096);
	if (!ib || !pattern_buffer())
		return -1;
	a6_tlb_flush(&st.hw);
	panel_stride(FB_STRIDE_GPU);
	struct a6_blit b;
	fit_blit(&b, SRC_IOVA, A6_GVA_FB, FB_STRIDE_GPU);
	uint32_t zero[64] = { 0 };
	for (uint32_t y = 0; y < FB_H; y++) {
		pm_wr(A6_FB_PA + (uint64_t)y * FB_STRIDE_GPU, zero, 4 * b.dx);
		pm_wr(A6_FB_PA + (uint64_t)y * FB_STRIDE_GPU + 4 * (b.dx + b.dw), zero, 4 * (FB_W - b.dx - b.dw));
	}
	uint32_t dw[A6_BLIT_MAX_DW], n = a6_blit_ib(&st.hw, &b, dw);
	pm_wr(bo_pa(ib), dw, 4ull * n);
	int rc = gpu_submit(bo_va(ib), n, 1000, NULL);
	glog("fb: fitted blit onto the panel -> %d (the kernel's own copies overwrite it; gpu test fbrestore)\n", rc);
	return rc;
}

int gpu_test(const char *which)
{
	if (!strcmp(which, "paint"))
		return test_paint();
	if (!strcmp(which, "blit"))
		return test_blit();
	if (!strcmp(which, "fb"))
		return test_fb();
	if (!strcmp(which, "fbrestore")) {
		panel_stride(FB_STRIDE);
		return 0;
	}
	return test_memwrite();
}

int gpu_up(int paint)
{
	pm_init();
	int a = gpu_attach();
	if (a == 0) {
		glog("gpu: already up (pool %llx); reboot to start over\n", (unsigned long long)st.hw.pool_pa);
		return 0;
	}
	if (a == -3 || a == -4) {
		glog("gpu: state from this boot but the GPU is not running our CP (%d); reboot first\n", a);
		return -1;
	}
	memset(&st, 0, sizeof(st));
	st.magic = STATE_MAGIC;
	st.version = STATE_VERSION;
	uint64_t pool = pm_alloc(A6_POOL_SIZE, A6_POOL_ALIGN);
	if (!pool)
		return -1;
	a6_init_state(&st.hw, pool);
	st.heap_next = A6_OFF_FREE;
	glog("gpu: pool %llx (%llu MB)\n", (unsigned long long)pool, A6_POOL_SIZE >> 20);
	gpu_save();
	int rc = a6_power_up(&st.hw);
	gpu_save();
	if (rc) {
		glog("gpu: bring-up FAILED (log above; gpu status)\n");
		return -1;
	}
	rc = test_memwrite();
	if (!rc && paint)
		rc = test_paint();
	return rc;
}

/* ---- replay of Mesa captures ---- */

static void replay_reset(void)
{
	for (uint32_t i = 0; i < st.nrep; i++)
		pm_free(st.rep[i].pa);
	st.nrep = 0;
	a6_unmap_high(&st.hw);
}

static int replay_buffer(uint64_t iova, uint32_t size)
{
	for (uint32_t i = 0; i < st.nrep; i++)
		if (st.rep[i].iova == iova && st.rep[i].size >= size)
			return (int)i;
	if (st.nrep >= sizeof(st.rep) / sizeof(st.rep[0]))
		return -1;
	uint64_t pa = pm_alloc(size, 0x1000);
	if (!pa)
		return -1;
	uint32_t i = st.nrep++;
	st.rep[i].iova = iova;
	st.rep[i].pa = pa;
	st.rep[i].size = size;
	return a6_map(&st.hw, iova, pa, size) ? -1 : (int)i;
}

int gpu_replay(const char *path, unsigned timeout_ms)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		glog("replay: %s: %s\n", path, strerror(errno));
		return -1;
	}
	replay_reset();
	int cur = -1, nsub = 0, rc = 0;
	uint32_t hdr[2];
	while (!rc && fread(hdr, 4, 2, f) == 2) {
		uint32_t type = hdr[0], size = hdr[1];
		uint8_t *body = malloc(size ? size : 1);
		if (fread(body, 1, size, f) != size) {
			free(body);
			break;
		}
		uint32_t *w = (uint32_t *)body;
		if (type == RD_GPUADDR && size >= 12) {
			uint64_t iova = w[0] | ((uint64_t)w[2] << 32);
			cur = replay_buffer(iova, w[1]);
			if (cur < 0) {
				glog("replay: cannot place buffer %llx size %x\n", (unsigned long long)iova, w[1]);
				rc = -1;
			}
		} else if (type == RD_BUFFER_CONTENTS && cur >= 0) {
			pm_wr(st.rep[cur].pa, body, size < st.rep[cur].size ? size : st.rep[cur].size);
		} else if (type == RD_CMDSTREAM_ADDR && size >= 12) {
			uint64_t iova = w[0] | ((uint64_t)w[2] << 32);
			a6_tlb_flush(&st.hw);
			gpu_save();
			rc = gpu_submit(iova, w[1], timeout_ms, NULL);
			glog("replay: submit %d: ib %llx, %u dwords -> %s\n", nsub++, (unsigned long long)iova, w[1],
			     rc ? "HANG/FAULT" : "ok");
		}
		free(body);
	}
	fclose(f);
	gpu_save();
	for (uint32_t i = 0; i < st.nrep; i++)
		glog("replay: buffer %u iova %llx size %llx at pa %llx\n", i, (unsigned long long)st.rep[i].iova,
		     (unsigned long long)st.rep[i].size, (unsigned long long)st.rep[i].pa);
	return rc;
}

/*
 * Which GPU VAs translate? Maps the scratch page at each test VA and lets
 * the CP write there. A faulting data write does not wedge the CP (an IB
 * fetch fault does), so this is safe.
 */
int gpu_vatest(int argc, char **argv)
{
	static uint64_t vas[16] = { 0x30000000ull, 0x40000000ull, 0xc0000000ull, 0xfffff000ull,
				    0x100000000ull, 0x180000000ull, 0x7f00000000ull };
	unsigned nva = 7;
	if (argc > 0)
		for (nva = 0; nva < (unsigned)argc && nva < 16; nva++)
			vas[nva] = strtoull(argv[nva], NULL, 0);
	replay_reset();
	for (unsigned i = 0; i < nva; i++) {
		uint64_t va = vas[i] & ~0xfffull, pa = pool_pa(A6_OFF_SCRATCH) + 0x200;
		if (a6_map(&st.hw, va, pool_pa(A6_OFF_SCRATCH), 0x1000))
			continue;
		a6_tlb_flush(&st.hw);
		wr32(pa, 0);
		uint32_t magic = 0x5a000000u | i;
		uint64_t dva = va + 0x200, far = 0;
		uint32_t dw[] = { a6_pkt7(A6_CP_MEM_WRITE, 3), (uint32_t)dva, (uint32_t)(dva >> 32), magic };
		gpu_submit_dwords(dw, 4, 500, NULL);
		uint32_t syn = 0, fsr = a6_fault_status(&st.hw, &far, &syn);
		glog("vatest: va %llx -> %s (fault %x fsynr0 %x far %llx)\n", (unsigned long long)vas[i],
		     rd32(pa) == magic ? "OK" : "no write", fsr, syn, (unsigned long long)far);
		gpu_clear_fault();
	}
	replay_reset();
	gpu_save();
	return 0;
}

/* ---- status and dumps ---- */

#define RBBM_STATUS		0x210
#define RBBM_INT_STATUS		0x201
#define CP_RB_RPTR		0x806
#define CP_RB_WPTR		0x807
#define CP_HW_FAULT		0x821
#define CP_STATUS_1		0x825
#define CP_IB1_BASE		0x928
#define CP_IB1_REM_SIZE		0x92a

void gpu_status(void)
{
	pm_init();
	printf("gcc: cfg_ahb %x axi %x memnoc %x\n", rd32(0x171004), rd32(0x171154), rd32(0x17100c));
	printf("gpucc: cx gdsc %x gx gdsc %x ahb %x cx_gmu %x\n", rd32(A6_GPUCC + 0x106c),
	       rd32(A6_GPUCC + 0x100c), rd32(A6_GPUCC + 0x1078), rd32(A6_GPUCC + 0x1098));
	int a = gpu_attach();
	static const char *why[] = { "attached", "no state file", "state from an earlier boot",
				     "GX off", "CP not running our SQE" };
	printf("state: %s", why[-a < 5 ? -a : 1]);
	if (a != -1)
		printf(" (pool %llx, gmu smr%d/cb%d, gpu smr%d/cb%d, %u submits, fence %u, %u bos, %u replay bufs)",
		       (unsigned long long)st.hw.pool_pa, st.hw.gmu_smr, st.hw.gmu_cb, st.hw.gpu_smr, st.hw.gpu_cb,
		       st.submits, st.hw.fence, st.nbo, st.nrep);
	printf("\n");
	if (!a6_cx_up()) {
		printf("CX side off: GMU registers not read\n");
		return;
	}
	printf("gmu: init_result %x hfi_ctrl %x rpmh_state %x cx_busy %x\n", rd32(A6_GREG(0x1f81c)),
	       rd32(A6_GREG(0x1f980)), rd32(A6_GREG(0x1f8ec)), rd32(A6_GREG(0x23b0c)));
	for (int cb = 0; cb < 5; cb++) {
		uint64_t c = A6_SMMU_CB(cb);
		uint32_t sctlr = rd32(c), fsr = rd32(c + 0x58);
		if (sctlr & 1 || (fsr & A6_FSR_FAULT))
			printf("smmu cb%d: sctlr %x tcr %x tcr2 %x fsr %x far %x:%x fsynr0 %x\n", cb, sctlr,
			       rd32(c + 0x30), rd32(c + 0x10), fsr, rd32(c + 0x64), rd32(c + 0x60), rd32(c + 0x68));
	}
	if (!a6_gx_up()) {
		printf("GX off: GPU registers not read\n");
		return;
	}
	printf("rbbm: status %x int %x; cp: rptr %x wptr %x (ours %x) hwfault %x status1 %x ib1 %x:%x rem %x\n",
	       rd32(A6_GREG(RBBM_STATUS)), rd32(A6_GREG(RBBM_INT_STATUS)), rd32(A6_GREG(CP_RB_RPTR)),
	       rd32(A6_GREG(CP_RB_WPTR)), st.hw.wptr, rd32(A6_GREG(CP_HW_FAULT)), rd32(A6_GREG(CP_STATUS_1)),
	       rd32(A6_GREG(CP_IB1_BASE + 1)), rd32(A6_GREG(CP_IB1_BASE)), rd32(A6_GREG(CP_IB1_REM_SIZE)));
	if (a == 0)
		printf("fence memory %u\n", a6_fence_read(&st.hw));
	for (uint32_t i = 0; i < st.nbo && a == 0; i++)
		printf("bo %-16s va %08llx pa %09llx size %llu\n", st.bo[i].name,
		       (unsigned long long)bo_va(&st.bo[i]), (unsigned long long)bo_pa(&st.bo[i]),
		       (unsigned long long)st.bo[i].size);
}

/* Linux's ascii85 (drm_print / devcoredump): 'z' for 0, 5 chars per word. */
static void ascii85(FILE *f, const uint32_t *w, uint32_t n)
{
	fputs("     ", f);
	for (uint32_t i = 0; i < n; i++) {
		uint32_t v = w[i];
		if (!v) {
			fputc('z', f);
			continue;
		}
		char out[5];
		for (int k = 4; k >= 0; k--) {
			out[k] = (char)('!' + v % 85);
			v /= 85;
		}
		fwrite(out, 1, 5, f);
	}
	fputc('\n', f);
}

static void dump_blob(FILE *f, const char *indent, uint64_t pa, uint32_t size)
{
	uint32_t *buf = calloc(1, size);
	if (!buf || pm_rd(pa, buf, size)) {
		free(buf);
		return;
	}
	fprintf(f, "%sdata: !!ascii85 |\n", indent);
	ascii85(f, buf, size / 4);
	free(buf);
}

static void dump_ranges(FILE *f, const uint32_t *r, unsigned n)
{
	for (unsigned i = 0; i + 1 < n; i += 2)
		for (uint32_t o = r[i]; o <= r[i + 1]; o++)
			fprintf(f, "  - { offset: 0x%06x, value: 0x%08x }\n", 4 * o, rd32(A6_GREG(o)));
}

/* linux a6xx_gpu_state.h: a6xx_registers (RBBM, CP, VSC, UCHE), ahb, gbif; GMU CX/AO, GX */
static const uint32_t regs_gpu[] = {
	0x0000, 0x0002, 0x0010, 0x0010, 0x0012, 0x0012, 0x0018, 0x001b, 0x001e, 0x0032, 0x0038, 0x003c,
	0x0042, 0x0042, 0x0044, 0x0044, 0x0047, 0x0047, 0x0056, 0x0056, 0x00ad, 0x00ae, 0x00b0, 0x00fb,
	0x0100, 0x011d, 0x0200, 0x020d, 0x0210, 0x0213, 0x0218, 0x023d, 0x0400, 0x04f9, 0x0500, 0x0500,
	0x0505, 0x050b, 0x050e, 0x0511, 0x0533, 0x0533, 0x0540, 0x0555,
	0x0800, 0x0808, 0x0810, 0x0813, 0x0820, 0x0821, 0x0823, 0x0827, 0x0830, 0x0833, 0x0840, 0x0845,
	0x084f, 0x086f, 0x0880, 0x088a, 0x08a0, 0x08ab, 0x08c0, 0x08c4, 0x08d0, 0x08dd, 0x08f0, 0x08f3,
	0x0900, 0x0903, 0x0908, 0x0911, 0x0928, 0x093e, 0x0942, 0x094d, 0x0980, 0x0984, 0x098d, 0x0996,
	0x0998, 0x099e, 0x09a0, 0x09a6, 0x09a8, 0x09ae, 0x09b0, 0x09b1, 0x09c2, 0x09c8, 0x0a00, 0x0a03,
	0x0c00, 0x0c04, 0x0c06, 0x0c06, 0x0c10, 0x0cd9, 0x0e00, 0x0e0e, 0x0e10, 0x0e13, 0x0e17, 0x0e19,
	0x0e1c, 0x0e2b, 0x0e30, 0x0e32, 0x0e38, 0x0e39, 0x0e3a, 0x0e3a,
	0x3c00, 0x3c0b, 0x3c40, 0x3c47, 0x3cc0, 0x3cd1,
};
static const uint32_t regs_gmu[] = {
	0x1f400, 0x1f407, 0x1f410, 0x1f412, 0x1f500, 0x1f500, 0x1f507, 0x1f50a, 0x1f800, 0x1f804,
	0x1f807, 0x1f808, 0x1f80b, 0x1f80c, 0x1f80f, 0x1f81c, 0x1f824, 0x1f82a, 0x1f82d, 0x1f830,
	0x1f840, 0x1f853, 0x1f887, 0x1f889, 0x1f8a0, 0x1f8a2, 0x1f8a4, 0x1f8af, 0x1f8c0, 0x1f8c3,
	0x1f8d0, 0x1f8d0, 0x1f8e4, 0x1f8e4, 0x1f8e8, 0x1f8ec, 0x1f900, 0x1f903, 0x1f940, 0x1f940,
	0x1f942, 0x1f944, 0x1f94c, 0x1f94d, 0x1f94f, 0x1f951, 0x1f954, 0x1f954, 0x1f957, 0x1f958,
	0x1f95d, 0x1f95d, 0x1f962, 0x1f962, 0x1f964, 0x1f965, 0x1f980, 0x1f986, 0x1f990, 0x1f99e,
	0x1f9c0, 0x1f9c0, 0x1f9c5, 0x1f9cc, 0x1f9e0, 0x1f9e2, 0x1f9f0, 0x1f9f0, 0x1fa00, 0x1fa01,
	0x23b00, 0x23b16, 0x23c00, 0x23c00,
};
static const uint32_t regs_gmu_gx[] = {
	0x1a800, 0x1a800, 0x1a810, 0x1a813, 0x1a816, 0x1a816, 0x1a818, 0x1a81b, 0x1a81e, 0x1a81e,
	0x1a820, 0x1a823, 0x1a826, 0x1a826, 0x1a828, 0x1a82b, 0x1a82e, 0x1a82e, 0x1a830, 0x1a833,
	0x1a836, 0x1a836, 0x1a838, 0x1a83b, 0x1a83e, 0x1a83e, 0x1a840, 0x1a843, 0x1a846, 0x1a846,
	0x1a880, 0x1a884, 0x1a900, 0x1a92b, 0x1a940, 0x1a940,
};

#define N(a) (sizeof(a) / sizeof((a)[0]))

/*
 * devcoredump layout of the msm driver (a6xx_show + adreno_show), the
 * subset Mesa's crashdec parses: header, fault-info, ringbuffer, bos, GMU
 * log, registers. "kernel: 6.19" makes crashdec take GMU offsets as GPU-base
 * relative, which is how they are written here.
 */
void gpu_dump(FILE *f, const char *reason)
{
	int a = gpu_attach();
	if (a == -1 || a == -2) {
		fprintf(stderr, "gpu dump: no state from this boot (gpu up first)\n");
		return;
	}
	fprintf(f, "kernel: 6.19.0-sweet\nmodule: sweet-pmem\ntime: %ld\ncomm: gpu\ncmdline: %s\n",
		(long)time(NULL), reason ? reason : "gpu dump");
	fprintf(f, "revision: %d (6.4.0.1)\n", A6_GPU_ID);
	if (!a6_cx_up()) {
		fprintf(f, "# CX side off: nothing else readable\n");
		return;
	}
	int gx = a6_gx_up();
	if (gx)
		fprintf(f, "rbbm-status: 0x%08x\n", rd32(A6_GREG(RBBM_STATUS)));
	uint64_t far = 0;
	uint32_t syn = 0, fsr = a6_fault_status(&st.hw, &far, &syn);
	if (fsr) {
		uint64_t c = A6_SMMU_CB(st.hw.gpu_cb);
		fprintf(f, "fault-info:\n  - ttbr0=%08x%08x\n  - iova=%016llx\n  - dir=%s\n  - type=SMMU\n",
			rd32(c + 0x24), rd32(c + 0x20), (unsigned long long)far, (syn & (1u << 4)) ? "WRITE" : "READ");
		fprintf(f, "  - fsr=0x%x fsynr0=0x%x\n", fsr, syn);
	}
	if (gx) {
		fprintf(f, "ringbuffer:\n  - id: 0\n    iova: 0x%016llx\n    last-fence: %u\n"
			   "    retired-fence: %u\n    rptr: %u\n    wptr: %u\n    size: %u\n",
			(unsigned long long)pool_va(A6_OFF_RING), st.hw.fence, a6_fence_read(&st.hw),
			rd32(A6_GREG(CP_RB_RPTR)), st.hw.wptr, A6_RING_SIZE);
		dump_blob(f, "    ", pool_pa(A6_OFF_RING), A6_RING_SIZE);
	}
	fprintf(f, "bos:\n  - iova: 0x%016llx\n    size: %u\n    name: scratch\n",
		(unsigned long long)pool_va(A6_OFF_SCRATCH), 0x1000);
	dump_blob(f, "    ", pool_pa(A6_OFF_SCRATCH), 0x1000);
	for (uint32_t i = 0; i < st.nbo; i++) {
		fprintf(f, "  - iova: 0x%016llx\n    size: %llu\n    name: %s\n",
			(unsigned long long)bo_va(&st.bo[i]), (unsigned long long)st.bo[i].size, st.bo[i].name);
		if (st.bo[i].size <= 0x100000)
			dump_blob(f, "    ", bo_pa(&st.bo[i]), (uint32_t)st.bo[i].size);
	}
	for (uint32_t i = 0; i < st.nrep; i++) {
		fprintf(f, "  - iova: 0x%016llx\n    size: %llu\n    name: replay%u\n",
			(unsigned long long)st.rep[i].iova, (unsigned long long)st.rep[i].size, i);
		if (st.rep[i].size <= 0x100000)
			dump_blob(f, "    ", st.rep[i].pa, (uint32_t)st.rep[i].size);
	}
	fprintf(f, "gmu-log:\n    iova: 0x%016llx\n    size: %u\n", (unsigned long long)A6_GMU_LOG_VA, A6_GMU_LOG_SIZE);
	dump_blob(f, "    ", pool_pa(A6_GMEM_LOG_OFF), A6_GMU_LOG_SIZE);
	if (gx) {
		fprintf(f, "registers:\n");
		dump_ranges(f, regs_gpu, N(regs_gpu));
	}
	fprintf(f, "registers-gmu:\n");
	dump_ranges(f, regs_gmu, N(regs_gmu));
	if (gx)
		dump_ranges(f, regs_gmu_gx, N(regs_gmu_gx));
	fflush(f);
}
