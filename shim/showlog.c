/*
 * Show-log mode (built with -DSHIM_SHOWLOG): put the logs an earlier run left
 * at the end of userdata on the screen, page by page, for the camera that
 * films the phone (tools/watch-boot.sh), then reset into fastboot. Needs no
 * Linux and writes nothing to UFS.
 *
 * Pages: the shim log of the previous run, then the tail of the XNU
 * persistent console ring (SHOWLOG_XNU_TAIL bytes). Every page starts with a
 * yellow title "<what> <page>/<pages> @<byte offset>".
 */
#include <stdint.h>
#include "console.h"
#include "log.h"
#include "showlog.h"
#include "ufs.h"
#include "util.h"

#ifndef SHOWLOG_XNU_TAIL
#define SHOWLOG_XNU_TAIL	(32 * 1024)
#endif
#ifndef SHOWLOG_PAGE_MS
#define SHOWLOG_PAGE_MS		4000
#endif

#define BLOCK		4096u
#define XNU_RING_SIZE	(4u << 20)	/* sweet_ufs.c SWEET_LOG_SIZE */

static char text[UFS_SCRATCH_BLOCKS * BLOCK] __attribute__((aligned(4096)));
static unsigned text_len;

struct sweetlog_header {
	char magic[8];
	uint32_t version, size;
	uint64_t total, seq;
};

/* what: page title, at most one console row ("<what> <page>/<pages> @<offset>"). */
static void show(const char *what, const char *s, unsigned len, uint32_t bg)
{
	unsigned starts[256], pages = 0, pos = 0;
	while (pos < len && pages < 256) {
		starts[pages++] = pos;
		con_home();
		con_skip();	/* the title row */
		pos += con_text(s + pos, len - pos, 0);
	}
	if (!pages)
		starts[pages++] = len;
	for (unsigned p = 0; p < pages; p++) {
		char title[64];
		unsigned n = fmt_snprintf(title, sizeof(title), "%s %u/%u @%u", what, p + 1, pages,
					  starts[p]);
		con_clear(bg);
		con_text(title, n, YELLOW);
		unsigned end = p + 1 < pages ? starts[p + 1] : len;
		con_text(s + starts[p], end - starts[p], WHITE);
		delay_ms(SHOWLOG_PAGE_MS);
	}
}

static unsigned printable_len(const char *s, unsigned max)
{
	unsigned n = 0;
	while (n < max && s[n])
		n++;
	return n;
}

static void show_shim_log(void)
{
	for (uint32_t i = 0; i < UFS_SCRATCH_BLOCKS; i += 16)
		if (ufs_scratch_read(i, 16, text + i * BLOCK)) {
			show("SHIMLOG read err", "", 0, 0xff400000);
			return;
		}
	text_len = printable_len(text, sizeof(text));
	show("SHIMLOG", text, text_len, 0xff102040);
}

static void show_xnu_log(void)
{
	static char blk[BLOCK] __attribute__((aligned(4096)));
	char msg[96];
	if (ufs_scratch_read(UFS_SCRATCH_BLOCKS, 1, blk)) {
		show("XNULOG read err", "", 0, 0xff400000);
		return;
	}
	struct sweetlog_header h;
	vcopy(&h, blk, sizeof(h));
	static const char want[8] = { 'S', 'W', 'E', 'E', 'T', 'L', 'O', 'G' };
	for (int i = 0; i < 8; i++)
		if (h.magic[i] != want[i]) {
			unsigned n = fmt_snprintf(msg, sizeof(msg), "no SWEETLOG header (%x %x %x %x)",
						  (uint8_t)blk[0], (uint8_t)blk[1], (uint8_t)blk[2],
						  (uint8_t)blk[3]);
			show("XNULOG", msg, n, 0xff402000);
			return;
		}
	unsigned n = fmt_snprintf(msg, sizeof(msg), "sweetlog v%u size %x total %lu seq %lu\n",
				  h.version, h.size, h.total, h.seq);
	if (h.size != XNU_RING_SIZE || !h.total) {
		show("XNULOG", msg, n, 0xff402000);
		return;
	}
	/* The last SHOWLOG_XNU_TAIL bytes, whole blocks, oldest first. */
	uint64_t want_bytes = h.total < SHOWLOG_XNU_TAIL ? h.total : SHOWLOG_XNU_TAIL;
	uint64_t from = h.total - want_bytes;
	vcopy(text, msg, n);
	text_len = n;
	for (uint64_t pos = from; pos < h.total;) {
		uint32_t off = pos % XNU_RING_SIZE, b = off / BLOCK;
		if (ufs_scratch_read(UFS_SCRATCH_BLOCKS + 1 + b, 1, blk)) {
			show("XNULOG read err", msg, n, 0xff400000);
			return;
		}
		uint32_t take = BLOCK - off % BLOCK;
		if (take > h.total - pos)
			take = h.total - pos;
		vcopy(text + text_len, blk + off % BLOCK, take);
		text_len += take;
		pos += take;
	}
	show("XNULOG", text, text_len, 0xff000000);
}

void showlog_run(int ufs_ok)
{
	if (!ufs_ok) {
		show("SHOWLOG no UFS", "", 0, 0xff400000);
		return;
	}
	show_shim_log();
	show_xnu_log();
	con_clear(0xff004000);
	con_text("SHOWLOG done", 12, YELLOW);
	delay_ms(SHOWLOG_PAGE_MS);
}
