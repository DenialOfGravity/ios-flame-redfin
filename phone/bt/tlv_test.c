/*
 * Host test for btd (cc -o tlv_test tlv_test.c tlv.c hci.c qca.c btd.c -DBTD_TEST && ./tlv_test):
 *   1. the TLV segmenter against a crbtfw32.tlv-sized synthetic rampatch in all four download modes
 *   2. the NVM edits on a synthetic crnv32.bin
 *   3. the whole `btd --scan 1` against a fake WCN3998 behind a fake UART: power pulses (only 0xFC at
 *      115200 with flow control off powers it), EDL version, baud change (bytes at the wrong speed are
 *      garbled), rampatch + NVM in segments (contents compared byte for byte), the acks each download mode
 *      implies, HCI Reset, Read_Local_Version, the BD address (0xFC0B), an LE scan with one advertiser.
 * No vendor file is used.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tlv.h"
#include "hci.h"
#include "uart.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }

/* a rampatch like crbtfw32.tlv: 118792 bytes, type 1 */
static uint8_t *make_patch(size_t n, uint8_t mode)
{
	uint8_t *b = malloc(n);
	for (size_t i = 0; i < n; i++)
		b[i] = (uint8_t)(i * 7 + 3);
	put32(b, (uint32_t)((n - 4) << 8 | TLV_TYPE_PATCH));
	put32(b + 4, (uint32_t)(n - 4));
	put32(b + 8, (uint32_t)(n - 28));
	b[12] = 2;		/* format */
	b[13] = 3;		/* signature */
	b[14] = mode;		/* download mode */
	b[15] = 0;
	put16(b + 16, 0x0008);	/* product */
	put16(b + 18, 0x0302);	/* rom build */
	put16(b + 20, 0x0123);	/* patch version */
	put16(b + 22, 0);
	put32(b + 24, 0x00080000);
	return b;
}

/* an NVM like crnv32.bin (5606 bytes): tags 1..N with tag 17, 27 and 2 among them */
static uint8_t *make_nvm(size_t *np)
{
	uint8_t *b = calloc(1, 8192);
	size_t o = 4;
	struct { uint16_t id, len; } tags[] = { { 1, 40 }, { 2, 6 }, { 17, 8 }, { 27, 4 }, { 40, 300 } };
	for (int round = 0; o < 5600 - 320; round++)
		for (unsigned t = 0; t < 5 && o < 5600 - 320; t++) {
			uint16_t id = round ? (uint16_t)(100 + round * 5 + t) : tags[t].id;
			put16(b + o, id);
			put16(b + o + 2, tags[t].len);
			memset(b + o + 12, 0x11 * (t + 1), tags[t].len);
			if (id == 17) {
				b[o + 12] = 0x00;	/* in-band sleep off */
				b[o + 12 + 2] = 0x00;	/* baud 115200 */
			}
			if (id == 27)
				b[o + 12] = 0x00;
			o += 12 + tags[t].len;
		}
	put32(b, (uint32_t)((o - 4) << 8 | TLV_TYPE_NVM));
	*np = o;
	return b;
}

static void test_segments(void)
{
	size_t n = 118792;
	struct tlv_seg s[600];
	for (int mode = 0; mode < 4; mode++) {
		size_t ns = tlv_segments(n, mode, s, 600);
		CHECK(ns == 489, "mode %d: %zu segments, want 489", mode, ns);
		size_t sum = 0, acks = 0;
		for (size_t i = 0; i < ns; i++) {
			CHECK(s[i].len >= 1 && s[i].len <= 243, "segment %zu len %u", i, s[i].len);
			CHECK(s[i].off == sum, "segment %zu off %u want %zu", i, s[i].off, sum);
			sum += s[i].len;
			acks += (size_t)s[i].want_ack;
		}
		CHECK(sum == n, "mode %d covers %zu of %zu", mode, sum, n);
		CHECK(s[ns - 1].len == 208, "last segment %u bytes, want 208", s[ns - 1].len);
		CHECK(s[ns - 1].want_ack, "mode %d: last segment must be acked", mode);
		size_t want = (mode == TLV_SKIP_VSE || mode == TLV_SKIP_VSE_CC) ? 1 : ns;
		CHECK(acks == want, "mode %d: %zu acks, want %zu", mode, acks, want);
	}
	/* exact multiple of 243: the last full segment is still acked */
	size_t ns = tlv_segments(243 * 4, TLV_SKIP_VSE_CC, s, 600);
	CHECK(ns == 4 && s[3].want_ack && !s[2].want_ack, "243*4: %zu segments", ns);
	CHECK(tlv_segments(0, 0, s, 600) == 0, "empty file");
	CHECK(tlv_segments(1, 3, s, 600) == 1 && s[0].len == 1 && s[0].want_ack, "1-byte file");
	/* max smaller than the count: count still reported, nothing written past max */
	CHECK(tlv_segments(n, 0, s, 3) == 489, "max");

	uint8_t *p = make_patch(n, 3);
	struct tlv_info ti;
	const char *err = NULL;
	CHECK(tlv_parse(p, n, &ti, &err) == 0, "parse patch: %s", err ? err : "");
	CHECK(ti.type == TLV_TYPE_PATCH && ti.dnld_mode == 3 && ti.rom_build == 0x0302 && ti.length == n - 4,
	      "patch fields: type %d mode %u rom %#x", ti.type, ti.dnld_mode, ti.rom_build);
	CHECK(tlv_parse(p, n - 1, &ti, &err) != 0, "truncated file must fail");
	free(p);
	CHECK(qca_rom_ver(0x40010320, 0x0302) == 0x32, "rom ver %#x", qca_rom_ver(0x40010320, 0x0302));
	CHECK(qca_rom_ver(0x40014320, 0x0201) == 0x21, "rom ver 3991");
}

static void test_nvm(void)
{
	size_t n;
	uint8_t *b = make_nvm(&n);
	struct tlv_info ti;
	const char *err = NULL;
	CHECK(tlv_parse(b, n, &ti, &err) == 0 && ti.type == TLV_TYPE_NVM && ti.hci_tag_len == 8,
	      "parse nvm: %s tags %d", err ? err : "", ti.ntags);
	uint8_t *copy = malloc(n);
	memcpy(copy, b, n);
	int c = tlv_nvm_edit(b, n, 14, 2, 0, NULL);
	CHECK(c == 1, "edit no-ibs baud 14: %d bytes changed, want 1", c);
	CHECK(b[4 + 52 + 18 + 12 + 2] == 14, "baud byte");
	c = tlv_nvm_edit(b, n, 14, 2, 1, NULL);
	CHECK(c == 2, "ibs on: %d changed, want 2 (tag 17 bit 7, tag 27 bit 0)", c);
	CHECK(b[4 + 52 + 18 + 12] == 0x80, "ibs bit");
	c = tlv_nvm_edit(b, n, 14, 2, 0, NULL);
	CHECK(c == 2, "ibs off again: %d", c);
	static const uint8_t addr[6] = { 1, 2, 3, 4, 5, 6 };
	c = tlv_nvm_edit(b, n, -1, 2, 0, addr);
	CHECK(c == 6, "bdaddr tag: %d", c);
	/* nothing else moved */
	size_t diff = 0;
	for (size_t i = 0; i < n; i++)
		diff += b[i] != copy[i];
	CHECK(diff == 7, "%zu bytes differ from the original, want 7 (baud + address)", diff);
	put16(b + 4 + 52 + 2, 60000);	/* break the tag list */
	CHECK(tlv_nvm_edit(b, n, 14, 2, 0, NULL) == -1, "malformed tag list must fail");
	free(b);
	free(copy);
}

/* ---- the fake controller ---- */

static const unsigned bauds[] = { 115200, 57600, 38400, 19200, 9600, 230400, 250000, 460800, 500000, 720000,
	921600, 1000000, 1250000, 2000000, 3000000, 4000000, 1600000, 3200000 };

static struct chip {
	struct uart u;
	int powered;
	unsigned baud;
	struct h4 rx;
	uint8_t out[1 << 16];
	size_t olen, opos;
	unsigned obaud[1 << 16];	/* the speed each output byte was sent at */
	uint8_t dl[1 << 18];
	size_t dlen, file_len;
	int files, mode, nvm_baud;
	const uint8_t *want[2];
	size_t want_len[2];
	uint8_t addr[6];
	int scanning, adv_sent, garbled, cmds_before_power, reset, nvm_diff_want;
	unsigned segs, vse_acks, cc_acks;
} chip;

static void emit(const uint8_t *b, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		chip.obaud[chip.olen] = chip.baud;
		chip.out[chip.olen++] = b[i];
	}
}

static void evt(uint8_t code, const uint8_t *p, uint8_t n)
{
	uint8_t b[260] = { H4_EVT, code, n };
	memcpy(b + 3, p, n);
	emit(b, 3u + n);
}

static void cc(uint16_t op, const uint8_t *ret, uint8_t n)
{
	uint8_t p[260] = { 1, (uint8_t)op, (uint8_t)(op >> 8) };
	memcpy(p + 3, ret, n);
	evt(EV_CMD_COMPLETE, p, 3u + n);
}

static void chip_cmd(const uint8_t *d, unsigned len)
{
	uint16_t op = (uint16_t)(d[0] | d[1] << 8);
	const uint8_t *p = d + 3;
	uint8_t ok = 0;
	if (!chip.powered) {
		chip.cmds_before_power++;
		return;
	}
	switch (op) {
	case 0xfc00:
		if (p[0] == 0x19) {
			uint8_t v[14] = { 0x00, 0x02 };
			put32(v + 2, 0x00000008);
			put16(v + 6, 0x0111);
			put16(v + 8, 0x0302);
			put32(v + 10, 0x40010320);
			evt(EV_VENDOR, v, 14);
		} else if (p[0] == 0x1e) {
			unsigned sl = p[1];
			CHECK(sl <= 243 && sl + 2 == d[2], "segment length %u plen %u", sl, d[2]);
			if (chip.file_len == 0) {
				uint32_t tl = p[2] | p[3] << 8 | p[4] << 16 | (uint32_t)p[5] << 24;
				chip.file_len = (tl >> 8) + 4;
				chip.mode = (tl & 0xff) == TLV_TYPE_PATCH ? p[2 + 14] : 0;
				chip.dlen = 0;
			}
			memcpy(chip.dl + chip.dlen, p + 2, sl);
			chip.dlen += sl;
			chip.segs++;
			int last = chip.dlen >= chip.file_len;
			int vse = chip.mode == 0 || chip.mode == 2 || last, ccc = chip.mode == 0 || chip.mode == 1 || last;
			if (vse) {
				uint8_t r[3] = { 0x00, 0x04, 0x00 };
				evt(EV_VENDOR, r, 3);
				chip.vse_acks++;
			}
			if (ccc) {
				cc(0xfc00, &ok, 1);
				chip.cc_acks++;
			}
			if (last) {
				int f = chip.files++;
				CHECK(f < 2 && chip.dlen == chip.want_len[f], "file %d: %zu bytes, want %zu", f, chip.dlen,
				      f < 2 ? chip.want_len[f] : 0);
				if (f == 0)
					CHECK(!memcmp(chip.dl, chip.want[0], chip.dlen), "rampatch content differs");
				if (f == 1) {
					/* the NVM arrives edited: baud index 14 at tag 17 [2], in-band sleep cleared */
					size_t diff = 0;
					for (size_t i = 0; i < chip.dlen; i++)
						diff += chip.dl[i] != chip.want[1][i];
					CHECK(diff == (size_t)chip.nvm_diff_want, "NVM: %zu bytes differ from the file, want %d (the baud index)",
					      diff, chip.nvm_diff_want);
					chip.nvm_baud = chip.dl[4 + 52 + 18 + 12 + 2];
				}
				chip.file_len = 0;
			}
		}
		break;
	case 0xfc48: {
		/* raw baud change: answer at the new speed once the host switched (vendor event 0x92) */
		chip.baud = bauds[p[0]];
		uint8_t r[2] = { 0x92, 0x00 };
		evt(EV_VENDOR, r, 2);
		break;
	}
	case 0x0c03:
		chip.reset++;
		cc(op, &ok, 1);
		break;
	case 0x1001: {
		uint8_t r[9] = { 0, 9, 0, 0, 9, 29, 0, 0x55, 0x01 };
		cc(op, r, 9);
		break;
	}
	case 0x1009: {
		uint8_t r[7] = { 0 };
		memcpy(r + 1, chip.addr, 6);
		cc(op, r, 7);
		break;
	}
	case 0xfc0b:
		CHECK(p[0] == 1 && p[1] == 2 && p[2] == 6, "FC0B params");
		memcpy(chip.addr, p + 3, 6);
		{
			uint8_t r[3] = { 0x00, 0x0b, 0x00 };
			evt(EV_VENDOR, r, 3);
		}
		break;
	case 0x200c:
		chip.scanning = p[0];
		cc(op, &ok, 1);
		break;
	default:
		cc(op, &ok, 1);
	}
	(void)len;
}

static int f_set_baud(struct uart *u, unsigned b) { u->baud = b; return 0; }
static int f_set_flow(struct uart *u, int on) { u->flow = on; return 0; }
static int f_drain(struct uart *u, unsigned ms) { (void)u; (void)ms; return 0; }
static void f_flush(struct uart *u) { (void)u; chip.opos = chip.olen; }
static void f_close(struct uart *u) { (void)u; }

static int f_write(struct uart *u, const uint8_t *b, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		uint8_t c = b[i];
		if (u->baud != chip.baud) {
			/* a power pulse is decoded by the circuit on TX, at the speeds Linux uses */
			if (c == 0xFC && u->baud == 115200 && !u->flow)
				chip.powered = 1, chip.baud = 115200;
			else
				chip.garbled++;
			continue;
		}
		if (c == 0xC0 && u->baud == 2400 && !u->flow) {
			chip.powered = 0;
			continue;
		}
		if (c == 0xFC && u->baud == 115200 && !u->flow && chip.rx.state == 0) {
			chip.powered = 1;
			continue;
		}
		if (h4_feed(&chip.rx, &c) == 1) {
			CHECK(chip.rx.type == H4_CMD, "host sent packet type %u", chip.rx.type);
			chip_cmd(chip.rx.data, chip.rx.got);
		}
	}
	return 0;
}

static int f_read(struct uart *u, uint8_t *b, size_t n, unsigned ms)
{
	(void)ms;
	if (chip.scanning && !chip.adv_sent) {
		uint8_t r[] = { 0x02, 1, 0x00, 0x00, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 10,
			0x02, 0x01, 0x06, 0x06, 0x09, 'P', 'i', 'x', 'e', 'l', (uint8_t)-60 };
		evt(EV_LE_META, r, sizeof(r));
		chip.adv_sent = 1;
	}
	size_t got = 0;
	if (!u->flow)
		return 0;	/* RTS held: the controller waits */
	while (chip.opos < chip.olen && got < n) {
		uint8_t c = chip.out[chip.opos];
		b[got++] = chip.obaud[chip.opos] == u->baud ? c : (uint8_t)(c ^ 0x5a);
		chip.opos++;
	}
	return (int)got;
}

int btd_main(int argc, char **argv);
static struct uart *fake;
struct uart *btuart_open(int verbose) { (void)verbose; return fake; }
struct uart *geni_open(int verbose, int os) { (void)verbose; (void)os; return NULL; }
int bt_rails_on(int verbose) { (void)verbose; return 0; }
int bt_sw_ctrl(void) { return chip.powered; }

static void write_file(const char *path, const uint8_t *b, size_t n)
{
	FILE *f = fopen(path, "wb");
	assert(f);
	fwrite(b, 1, n, f);
	fclose(f);
}

static void test_flow(int mode, const char *baud)
{
	memset(&chip, 0, sizeof(chip));
	chip.baud = 9600;	/* off: whatever */
	chip.u = (struct uart){ .name = "fake", .baud = 115200, .flow = 1, .set_baud = f_set_baud,
		.set_flow = f_set_flow, .write = f_write, .drain = f_drain, .read = f_read, .flush_rx = f_flush,
		.close = f_close };
	fake = &chip.u;
	size_t pn = 118792, nn;
	uint8_t *p = make_patch(pn, (uint8_t)mode), *nv = make_nvm(&nn);
	write_file("/tmp/btd-test-fw.tlv", p, pn);
	write_file("/tmp/btd-test-nvm.bin", nv, nn);
	chip.want[0] = p;
	chip.want_len[0] = pn;
	chip.want[1] = nv;
	chip.want_len[1] = nn;
	chip.nvm_diff_want = strcmp(baud, "115200") != 0;
	char *argv[] = { "btd", "--scan", "1", getenv("BTD_TEST_LOG") ? "-v" : "-q", "--baud", (char *)baud, "--fw", "/tmp/btd-test-fw.tlv",
		"--nvm", "/tmp/btd-test-nvm.bin", "--bdaddr", "02:50:49:58:45:4d", NULL };
	int rc = btd_main(12, argv);
	CHECK(rc == 0, "mode %d baud %s: btd --scan returned %d", mode, baud, rc);
	CHECK(chip.files == 2, "mode %d: %d files downloaded", mode, chip.files);
	CHECK(chip.segs == 489 + (nn + 242) / 243, "mode %d: %u segments", mode, chip.segs);
	CHECK(chip.reset == 1, "HCI reset count %d", chip.reset);
	CHECK(chip.adv_sent, "no scan");
	CHECK(chip.addr[0] == 0x4d && chip.addr[5] == 0x02, "BD address little endian: %02x..%02x", chip.addr[0], chip.addr[5]);
	if (strcmp(baud, "115200"))
		CHECK(chip.baud == 3000000 && chip.nvm_baud == 14, "chip speed %u, NVM baud index %d", chip.baud, chip.nvm_baud);
	CHECK(chip.cmds_before_power == 0, "%d commands before the power pulse", chip.cmds_before_power);
	printf("mode %d baud %s: %u segments, %u vendor acks, %u command completes, %d garbled bytes\n", mode, baud,
	       chip.segs, chip.vse_acks, chip.cc_acks, chip.garbled);
	free(p);
	free(nv);
}

int main(void)
{
	test_segments();
	test_nvm();
	for (int mode = 0; mode < 4; mode++)
		test_flow(mode, "3000000");
	test_flow(3, "115200");
	printf("%s (%d failures)\n", fails ? "FAILED" : "all passed", fails);
	return fails != 0;
}
