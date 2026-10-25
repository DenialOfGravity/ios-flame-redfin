/*
 * fastrpcd transport: what Linux's/Android's fastrpc kernel driver does for hexagonrpcd, in userland,
 * over /dev/redwood-fastrpc (XNU patch 0950) and physical buffers read and written through /dev/pmem.
 * Copyright (C) 2026 the ios-flame contributors. GPL-3.0-or-later (part of fastrpcd).
 */
#ifndef FASTRPCD_TRANSPORT_H
#define FASTRPCD_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>
#include <misc/fastrpc.h>

#define FRPC_PAGE		4096u
#define FRPC_ALIGN		128u	/* BALIGN / FASTRPC_ALIGN */
#define FRPC_FDLIST		16
#define FRPC_CRCLIST		64
#define FRPC_MAX_BUFS		32
#define FRPC_SID		0x1403u	/* adsprpc compute cb10 */
#define FRPC_SESSION		(FRPC_SID & 0xfu)	/* 3: addr = PA | session << 32 */
#define FRPC_INIT_HANDLE	1
#define FRPC_ROOT_PD		0
#define FRPC_SENSORS_PD		2

/* The message to the DSP (Linux struct fastrpc_msg / Android smq_msg): 40 bytes. */
struct frpc_msg {
	int32_t client, thread;
	uint64_t ctx;
	uint32_t handle, sc;
	uint64_t addr, size;
};

/* Where each argument went in the buffer. */
struct frpc_layout {
	size_t metalen;		/* remote args + invoke bufs + pages + fdlist + crclist + early hint */
	size_t used;		/* metadata and inline buffers */
	size_t off[FRPC_MAX_BUFS];	/* offset of argument i's bytes in the buffer (0: empty) */
};

/*
 * Lay out one invocation as Android's adsprpc.c get_args() does (no ION maps, no handles): at 0
 * remote_arg64[n] {pv, len}, then smq_invoke_buf[n] {num, pgidx}, smq_phy_page[n] {addr, size},
 * u64 fdlist[16], u32 crclist[64], u32 early-wake hint; each buffer at the next 128-byte boundary.
 * pv = PA of the bytes (the DSP takes only the page offset from it), page addr = page of the bytes
 * | session << 32, page size = pages spanned * 4 KiB. img (cap bytes) receives the metadata and the
 * input buffers' bytes. Returns 0, or -1 if it does not fit or there are handles / too many buffers.
 */
int frpc_layout(uint32_t sc, const struct fastrpc_invoke_args *args, uint64_t pa, uint32_t session,
		uint8_t *img, size_t cap, struct frpc_layout *lay);

/* Memory: the DSP's buffers, contiguous, below 4 GiB. */
struct frpc_mem {
	int (*alloc)(void *ctx, uint64_t size, uint64_t *pa);
	int (*wr)(void *ctx, uint64_t pa, const void *buf, size_t len);
	int (*rd)(void *ctx, uint64_t pa, void *buf, size_t len);
	void *ctx;
};

/* Device side: write a message, read an answer (raw bytes). Overridden by the unit test. */
struct frpc_dev {
	int (*send)(void *ctx, const struct frpc_msg *m);
	int (*recv)(void *ctx, void *answer, size_t cap);	/* bytes, or -1 and errno */
	void *ctx;
};

int frpc_start(const struct frpc_dev *dev, const struct frpc_mem *mem);	/* starts the answer reader */
void frpc_stop(void);
int frpc_session_new(int32_t client);	/* a pseudo fd for fastrpc_ioctl(); its PD is set by INIT_ATTACH(_SNS) */
int frpc_dead(void);			/* the DSP has gone (ECONNRESET) */
extern int frpc_mmap_method;		/* INIT_MMAP: 4 (Linux, default) or 2 (Android 64-bit) */

/* The real device and memory: /dev/redwood-fastrpc (+ FASTRPC_ALLOC) and /dev/pmem. */
int frpc_open_device(const char *path, struct frpc_dev *dev, struct frpc_mem *mem);
void frpc_close_device(void);

#endif
