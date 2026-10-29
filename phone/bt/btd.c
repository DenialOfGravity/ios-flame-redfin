/*
 * btd: Bluetooth stage 1 for redfin (Pixel 5): the WCN3998's HCI from userland, no kernel driver needed.
 * The controller sits behind QUPv3 wrapper 0 SE5 (0x894000, 4-wire UART, GPIO 38-41); btd votes its rails,
 * clocks the SE, sends the WCN399x power pulses, loads the Qualcomm rampatch + NVM and talks plain HCI.
 * UART backend: /dev/btuart when the kernel has it (0981, boot-arg btuart=1), else /dev/pmem polling.
 *
 *   btd --probe          rails, SE5 firmware check (GENI_FW_REVISION_RO protocol 2), power pulses, EDL
 *                        version (SoC id / ROM): no download
 *   btd --up             the whole bring-up: baud change, rampatch, NVM, HCI Reset, Read_Local_Version
 *                        (manufacturer 29), BD address from the ADT (/chosen mac-address-bluetooth0)
 *   btd --scan [SECS]    --up, then a passive LE scan (default 5 s), one line per advertisement
 *   btd --raw [PORT]     --up, then H4 passthrough on TCP 127.0.0.1:PORT (default 2225) for a host stack
 *   btd --bridge [DEV]   --up, then bridge iOS's Bluetooth stack: HCI from DEV (default /dev/btbridge,
 *                        kernel 0983) to the WCN3998 and back, every packet logged, vendor 0xFC__ commands
 *                        answered with Command Complete status 0 (not sent to the QCA chip) unless
 *                        --bridge-forward-vendor. Run with sweetbtnub=7 btbridge=1 so bluetoothd attaches.
 *                        ws-y-bt: the loop reads /dev/btbridge non-blocking every pass and sleeps in select():
 *                        poll() on that node returns POLLNVAL at once (1010's cdevsw is not kqueue-ok), which
 *                        is why btd up to f6fc88e never read a byte of bluetoothd's and spun at 100% CPU.
 *                        HCI shim (hakios-sm8150 vayu_bt_vsc): --bridge-vsc 0|1|2 or env BTD_VSC, default 1:
 *                          1: Read_Local_Supported_Commands octet 18 bit 3 set in the answer, 0x0c5b answered
 *                             here (status 0), 0xfd48 answered here (status 0x01); other vendor commands go
 *                             to the WCN3998 except QCA's own 0xFC00/0xFC0B/0xFC48 (answered here);
 *                          2: 1 + every other vendor command answered here with status 0 (the pre-ws-y default);
 *                          0: no rules. Each rule is logged once ("BTD SHIM:"), counts at exit.
 *                        In-band sleep: the NVM keeps it off (as --scan, vayu_bt_ibs=0), but the WCN3998 still
 *                        sends 0xFE when idle and 0xFD (wake indication) before it answers; btd acknowledges
 *                        every 0xFD with 0xFC, and with env BTD_IBS=1 (default) sends 0xFD and waits for 0xFC
 *                        before a packet after a 0xFE (BTD_IBS=0: never). These bytes never reach the host.
 *                        ws-y-bt2: up to 68cef4c hci.h had 0xFD/0xFE swapped, so 0xFD was never acknowledged
 *                        (r57a: 25000+ "sleep indications", bluetoothd's Reset unanswered).
 *                        /dev/btbridge missing: "BTD FAIL bridge-open" before any radio work, exit 0 (launchd
 *                        does not restart a successful exit).
 * Options: --baud N (operating speed, default 3000000; 115200 = no change), --os 16|32 (UART oversampling,
 *   default from the QUP version), --pmem (ignore /dev/btuart), --fwdir DIR (default /private/var/local/fw),
 *   --fw FILE, --nvm FILE, --ibs (keep the NVM's in-band sleep / deep sleep as Linux sets them),
 *   --setaddr (write a BD address: --bdaddr's, else the ADT's; default: keep the controller's own -- on redfin
 *   the 0xFC0B write was followed by the controller going silent), --bdaddr XX:XX:XX:XX:XX:XX (implies --setaddr),
 *   --nvm-keep (NVM exactly as the file), --nvm-baud-pos N (tag 17 byte for the baud index), --noinit (controller already up at --baud: skip power-up and download),
 *   -v (full hex of every packet), -q (no per-packet log).
 * Every HCI packet is logged ("BTD >" to the controller, "BTD <" from it); result lines start with
 * "BTD PROBE", "BTD UP", "BTD ADV", "BTD SCAN", "BTD RAW", failures with "BTD FAIL <step>".
 * Firmware (vendor files, not in git): crbtfw32.tlv, crnv32.bin / crnv32u.bin from /vendor/firmware.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#endif
#include "hci.h"
#include "qca.h"
#include "tlv.h"

#ifdef BTD_TEST
#define main btd_main
int btd_main(int argc, char **argv);
#endif

struct opts {
	int mode;		/* 'p' probe, 'u' up, 's' scan, 'r' raw */
	unsigned secs, port, baud;
	int os, pmem, ibs, noinit, verbose, have_addr, setaddr, nvm_keep, nvm_pos, fwd_vendor, vsc;
	const char *bridge_dev_path;
	const char *fwdir, *fw, *nvm;
	uint8_t addr[6];
};

static void usage(void)
{
	fprintf(stderr, "usage: btd --probe | --up | --scan [SECS] | --raw [PORT]  [--baud N] [--os 16|32] [--pmem]\n"
		"           [--fwdir DIR] [--fw FILE] [--nvm FILE] [--ibs] [--nvm-keep] [--nvm-baud-pos N] [--setaddr]\n"
		"           [--bdaddr XX:..] [--noinit] [--bridge [DEV]] [--bridge-forward-vendor] [--bridge-raw]\n"
		"           [--bridge-vsc 0|1|2 (env BTD_VSC, default 1)] [-v|-q]\n");
	exit(2);
}

static int parse_addr(const char *s, uint8_t a[6])
{
	unsigned v[6];
	if (sscanf(s, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6)
		return -1;
	for (int i = 0; i < 6; i++)
		a[i] = (uint8_t)v[i];
	return 0;
}

/* /chosen mac-address-bluetooth0 from the ADT (tools/mkadt.py; a locally administered address) */
static int adt_addr(uint8_t a[6])
{
#ifdef __APPLE__
	io_registry_entry_t e = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
	if (!e)
		return -1;
	CFTypeRef p = IORegistryEntryCreateCFProperty(e, CFSTR("mac-address-bluetooth0"), kCFAllocatorDefault, 0);
	IOObjectRelease(e);
	int rc = -1;
	if (p && CFGetTypeID(p) == CFDataGetTypeID() && CFDataGetLength(p) >= 6) {
		CFDataGetBytes(p, CFRangeMake(0, 6), a);
		rc = 0;
	}
	if (p)
		CFRelease(p);
	return rc;
#else
	(void)a;
	return -1;
#endif
}

static void fail(struct hci *h, const char *step, const char *meaning)
{
	if (h)
		hci_log(h, "BTD FAIL %s: %s\n", step, meaning);
	else
		printf("BTD FAIL %s: %s\n", step, meaning);
}

/* ---- LE scan ---- */

struct seen {
	uint8_t addr[6];
	unsigned count;
};
static struct seen seen[256];
static unsigned nseen, nreports;

static void adv_name(const uint8_t *d, unsigned n, char *out, size_t cap)
{
	out[0] = 0;
	for (unsigned i = 0; i + 1 < n;) {
		unsigned l = d[i];
		if (!l || i + 1 + l > n)
			break;
		uint8_t t = d[i + 1];
		if (t == 0x08 || t == 0x09) {
			unsigned k = l - 1 < cap - 1 ? l - 1 : (unsigned)cap - 1;
			for (unsigned j = 0; j < k; j++) {
				uint8_t c = d[i + 2 + j];
				out[j] = c >= 32 && c < 127 ? (char)c : '.';
			}
			out[k] = 0;
			if (t == 0x09)
				return;
		}
		i += 1 + l;
	}
}

static void on_async(struct hci *h, const struct hci_pkt *p)
{
	if (p->type != H4_EVT || p->data[0] != EV_LE_META || p->len < 4 || p->data[2] != 0x02)
		return;
	const uint8_t *d = p->data + 3, *end = p->data + p->len;
	unsigned num = *d++;
	for (unsigned r = 0; r < num && d + 9 <= end; r++) {
		uint8_t evt = d[0], at = d[1];
		const uint8_t *a = d + 2;
		unsigned dl = d[8];
		if (d + 9 + dl + 1 > end)
			break;
		const uint8_t *ad = d + 9;
		int8_t rssi = (int8_t)ad[dl];
		char name[40];
		adv_name(ad, dl, name, sizeof(name));
		nreports++;
		unsigned i;
		for (i = 0; i < nseen; i++)
			if (!memcmp(seen[i].addr, a, 6))
				break;
		if (i == nseen && nseen < 256)
			memcpy(seen[nseen++].addr, a, 6);
		if (i < 256)
			seen[i].count++;
		hci_log(h, "BTD ADV %02x:%02x:%02x:%02x:%02x:%02x %s type %u rssi %d len %u%s%s\n", a[5], a[4], a[3],
			a[2], a[1], a[0], at == 0 ? "public" : at == 1 ? "random" : "other", evt, rssi, dl,
			name[0] ? " name " : "", name);
		d += 9 + dl + 1;
	}
}

static int le_scan(struct hci *h, unsigned secs)
{
	/* event mask with LE Meta (bit 61) on top of the default; LE mask default (advertising report in it) */
	static const uint8_t evmask[8] = { 0xff, 0xff, 0xfb, 0xff, 0x07, 0xf8, 0xbf, 0x3d };
	static const uint8_t lemask[8] = { 0x1f, 0, 0, 0, 0, 0, 0, 0 };
	/* passive, interval = window = 10 ms (0x10 * 0.625), public own address, accept all */
	static const uint8_t params[7] = { 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00 };
	uint8_t on[2] = { 0x01, 0x00 }, off[2] = { 0x00, 0x00 };
	nseen = nreports = 0;
	h->on_async = on_async;
	if (hci_cmd(h, 0x0c01, evmask, 8, NULL, NULL, 2000) || hci_cmd(h, 0x2001, lemask, 8, NULL, NULL, 2000) ||
	    hci_cmd(h, 0x200b, params, 7, NULL, NULL, 2000)) {
		fail(h, "scan-setup", "the controller refused the event masks or scan parameters (firmware not running?)");
		qca_baud_probe(h);
		return -1;
	}
	if (hci_cmd(h, 0x200c, on, 2, NULL, NULL, 2000)) {
		fail(h, "scan-enable", "LE_Set_Scan_Enable refused");
		return -1;
	}
	hci_log(h, "BTD SCAN: passive LE scan for %u s\n", secs);
	hci_drain(h, secs * 1000);
	hci_cmd(h, 0x200c, off, 2, NULL, NULL, 2000);
	hci_log(h, "BTD SCAN: %u advertising reports from %u devices in %u s%s\n", nreports, nseen, secs,
		nreports ? "" : " (none: antenna/RF path, or no advertisers nearby)");
	return nreports ? 0 : 1;
}

/* ---- raw H4 bridge ---- */

static int raw_sock = -1;

static void raw_tap(struct hci *h, uint8_t type, const uint8_t *data, size_t len)
{
	(void)h;
	if (raw_sock < 0 || !data)
		return;		/* in-band sleep bytes stay here (hci.c answers them) */
	uint8_t b[1 + H4_MAX];
	b[0] = type;
	memcpy(b + 1, data, len);
	if (send(raw_sock, b, len + 1, 0) < 0) {
		close(raw_sock);
		raw_sock = -1;
	}
}

static int raw_bridge(struct hci *h, unsigned port)
{
	int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);
	sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	if (ls < 0 || bind(ls, (struct sockaddr *)&sa, sizeof(sa)) || listen(ls, 1)) {
		fail(h, "raw-listen", strerror(errno));
		return -1;
	}
	h->tap = raw_tap;
	hci_log(h, "BTD RAW: H4 passthrough on 127.0.0.1:%u (ssh -L %u:127.0.0.1:%u, then e.g. socat + btattach)\n",
		port, port, port);
	struct h4 cp;
	memset(&cp, 0, sizeof(cp));
	for (;;) {
		struct pollfd pf[1] = { { raw_sock >= 0 ? raw_sock : ls, POLLIN, 0 } };
		poll(pf, 1, 1);
		if (raw_sock < 0 && (pf[0].revents & POLLIN)) {
			raw_sock = accept(ls, NULL, NULL);
			if (raw_sock >= 0) {
				setsockopt(raw_sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
				hci_log(h, "BTD RAW: client connected\n");
			}
		} else if (raw_sock >= 0 && (pf[0].revents & (POLLIN | POLLHUP | POLLERR))) {
			uint8_t b[1024];
			ssize_t n = recv(raw_sock, b, sizeof(b), 0);
			if (n <= 0) {
				hci_log(h, "BTD RAW: client gone\n");
				close(raw_sock);
				raw_sock = -1;
				continue;
			}
			for (ssize_t i = 0; i < n; i++) {
				uint8_t c = b[i];
				int r = h4_feed(&cp, &c);
				if (r == 1 && h->verbose >= 1)
					hci_log_pkt(h, 1, cp.type, cp.data, cp.got);
				else if (r >= 2)
					hci_log(h, "BTD RAW: client sent stray byte 0x%02x\n", c);
			}
			if (h->u->write(h->u, b, (size_t)n) < 0)
				hci_log(h, "BTD RAW: UART write failed\n");
		}
		struct hci_pkt p;
		while (hci_recv(h, &p, 0) > 0)
			;
	}
}

/* ---- /dev/btbridge: drive bluetoothd/BlueTool over the WCN3998 (0983) ---- */

#define BTD_READY	"/private/var/tmp/btd-bridge.pid"
static int bridge_fd = -1;
static unsigned bridge_fake, bridge_fwd, bridge_fixed;
/*
 * redfin 2026-10-28, HCI compatibility for bluetoothd (ios-asteroids' WCN3990 findings, docs/WIFI_BT_IOS18.md
 * 0239): Apple's stack treats some answers of a non-Broadcom controller as fatal. With compat on (default;
 * --bridge-raw turns it off):
 *  - a vendor command we answer gets status 0, the command's first parameter byte (its sub-opcode, which
 *    _BCM_SubOpcodeChecker compares) and 8 zero bytes;
 *  - the controller's "Unknown HCI Command" (status 0x01) in a Command Complete becomes success, padded the same way;
 *  - "Command Disallowed" (0x0c) for LE scan/advertising parameters/enable (0x2006/07/0a/0b/0c) becomes success.
 * Each rewrite is logged ("BTD BRIDGE: fixed").
 */
static int bridge_compat = 1;
static uint16_t last_op;
static uint8_t last_sub, last_has_sub;

static int le_disallowed_ok(uint16_t op)
{
	return op == 0x2006 || op == 0x2007 || op == 0x200a || op == 0x200b || op == 0x200c;
}

/*
 * ws-y-bt: the vayu-style shim (hakios-sm8150 kernel/bsd/dev/vayu_bt.c, bt_vsc_rules + bt_sc_rewrite), here in
 * userland. bluetoothd's init (H4BC) aborts with reason 0x6c when 0x0c5b Write_Default_Erroneous_Data_Reporting
 * is not offered (Supported_Commands octet 18 bit 3, clear on Qualcomm) or not answered; it asserts in
 * bcm_vsc.c on an empty status-0 answer to 0xfd48 (create multi-adv instance) but accepts status 0x01.
 */
static int bridge_nvm_ibs;		/* --ibs given: NVM in-band sleep left on */
static int bridge_vsc = 1;		/* 0 off, 1 rules, 2 rules + vendor catch-all */
enum { SR_SC18, SR_0C5B, SR_FD48, SR_QCA_GUARD, SR_VSC_ALL, SR_VSC_FWD, SR_N };
static const char *const sr_name[SR_N] = {
	"supported-commands-octet18", "0x0c5b-local", "0xfd48-local-status1", "qca-opcode-guard",
	"vendor-catch-all", "vendor-forwarded",
};
static unsigned sr_hits[SR_N];
static unsigned long bridge_host_bytes, bridge_host_pkts, bridge_ctrl_pkts;
static unsigned bridge_wr_errs;

static void shim_hit(struct hci *h, int r, uint16_t op, const char *what)
{
	if (sr_hits[r]++ == 0)
		hci_log(h, "BTD SHIM: rule %s: op 0x%04x %s (logged once; count at exit)\n", sr_name[r], op, what);
}

/* QCA's own vendor opcodes (EDL/patch download, NVM/BD address write, baud change): a Broadcom command with the
   same number must never reach the WCN3998 (0xFC48 would move its UART speed under btd) */
static int qca_reserved(uint16_t op)
{
	return op == 0xfc00 || op == 0xfc0b || op == 0xfc48;
}

/* all of it to the host side, the fd is non-blocking: retry a full ring for up to ~200 ms */
static void bridge_write(struct hci *h, const uint8_t *b, size_t n)
{
	for (int tries = 0; n && tries < 200;) {
		ssize_t w = write(bridge_fd, b, n);
		if (w > 0) {
			b += w;
			n -= (size_t)w;
			continue;
		}
		if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
			break;
		tries++;
		usleep(1000);
	}
	if (n && bridge_wr_errs++ < 8)
		hci_log(h, "BTD BRIDGE: %zu bytes for the host dropped (%s)\n", n, strerror(errno));
}

/* a Command Complete made here: ncmd 1, status, n return bytes */
static void bridge_local_cc(struct hci *h, uint16_t op, uint8_t status, const uint8_t *ret, uint8_t n)
{
	uint8_t e[7 + 32] = { H4_EVT, EV_CMD_COMPLETE, (uint8_t)(4 + n), 1, (uint8_t)op, (uint8_t)(op >> 8), status };
	if (n > 32)
		n = 32;
	if (n)
		memcpy(e + 7, ret, n);
	if (h->verbose >= 1)
		hci_log(h, "BTD BRIDGE: local Command Complete op 0x%04x status 0x%02x to the host\n", op, status);
	bridge_write(h, e, 7u + n);
}

/* events/ACL from the controller to the iOS side (hci.c tap; IBS bytes have data == NULL and stay here) */
static unsigned long bridge_ibs_dropped[3];	/* 0xFD wake ind, 0xFE sleep ind, 0xFC wake ack */
static void bridge_tap(struct hci *h, uint8_t type, const uint8_t *data, size_t len)
{
	if (bridge_fd < 0)
		return;
	if (!data) {
		/* a single in-band sleep byte (0xFD/0xFE/0xFC between packets): hci.c answers it, bluetoothd's H4
		   (H4BC) would read it as a packet type, so it never goes to the host (vayu filters them too) */
		int k = type == IBS_WAKE_IND ? 0 : type == IBS_SLEEP_IND ? 1 : 2;
		if (bridge_ibs_dropped[0] + bridge_ibs_dropped[1] + bridge_ibs_dropped[2] == 0)
			hci_log(h, "BTD BRIDGE: in-band sleep byte 0x%02x from the WCN3998 kept from the host (all of them; "
				"counts at exit)\n", type);
		bridge_ibs_dropped[k]++;
		return;
	}
	if (bridge_compat && type == H4_EVT && len >= 6 && data[0] == EV_CMD_COMPLETE) {
		uint16_t op = (uint16_t)(data[3] | data[4] << 8);
		uint8_t st = data[5];
		if (st == 0x01 || (st == 0x0c && le_disallowed_ok(op))) {
			uint8_t e[1 + 2 + 13] = { H4_EVT, EV_CMD_COMPLETE };
			size_t n;
			if (st == 0x01) {
				e[2] = 13;
				e[3] = data[2];
				e[4] = data[3];
				e[5] = data[4];
				e[6] = 0;
				e[7] = op == last_op && last_has_sub ? last_sub : 0;
				n = 3 + 13;
			} else {
				n = 1 + len;
				memcpy(e + 1, data, len < sizeof(e) - 1 ? len : sizeof(e) - 1);
				e[6] = 0;
			}
			hci_log(h, "BTD BRIDGE: fixed Command Complete 0x%04x status 0x%02x -> 0 (%u so far)\n", op, st, ++bridge_fixed);
			bridge_write(h, e, n);
			return;
		}
	}
	uint8_t b[1 + H4_MAX];
	b[0] = type;
	memcpy(b + 1, data, len);
	bridge_ctrl_pkts++;
	/* Read_Local_Supported_Commands: 0e 44 01 02 10 00 + 64 octets, octet k at data[6 + k] */
	if (bridge_vsc >= 1 && type == H4_EVT && len >= 6 + 19 && data[0] == EV_CMD_COMPLETE && data[3] == 0x02 &&
	    data[4] == 0x10 && data[5] == 0x00) {
		uint8_t was = data[6 + 18];
		b[1 + 6 + 18] = (uint8_t)(was | 0x08);
		char what[96];
		snprintf(what, sizeof(what), "answer: octet 18 0x%02x -> 0x%02x (0x0c5b advertised)", was, b[1 + 6 + 18]);
		shim_hit(h, SR_SC18, 0x1002, what);
	}
	bridge_write(h, b, len + 1);
}

/* a Command Complete (ncmd 1, status 0) for a vendor command we answer instead of forwarding */
static void bridge_fake_cc(struct hci *h, uint16_t op)
{
	uint8_t e[16] = { H4_EVT, EV_CMD_COMPLETE, 4, 1, (uint8_t)op, (uint8_t)(op >> 8), 0x00 };
	size_t n = 7;
	if (bridge_compat) {
		e[2] = 13;			/* + sub-opcode + 8 zero bytes */
		e[7] = last_has_sub ? last_sub : 0;
		n = 16;
	}
	bridge_write(h, e, n);
	if (h->verbose >= 1)
		hci_log(h, "BTD BRIDGE: faked Command Complete status 0 for vendor op 0x%04x (%u so far)\n", op, ++bridge_fake);
	else
		bridge_fake++;
}

static void bridge_host_pkt(struct hci *h, const struct h4 *cp)
{
	if (h->verbose >= 1)
		hci_log_pkt(h, 1, cp->type, cp->data, cp->got);
	if (cp->type == H4_CMD) {
		uint16_t op = (uint16_t)(cp->data[0] | cp->data[1] << 8);
		int vendor = (op >> 10) == 0x3f;	/* OGF 0x3f = 0xFC00..0xFFFF */
		last_op = op;
		last_has_sub = cp->got > 3 && cp->data[2] > 0;
		last_sub = last_has_sub ? cp->data[3] : 0;
		bridge_host_pkts++;
		if (bridge_vsc >= 1 && op == 0x0c5b) {
			shim_hit(h, SR_0C5B, op, "Write_Default_Erroneous_Data_Reporting answered here, status 0");
			bridge_local_cc(h, op, 0x00, NULL, 0);
			return;
		}
		if (bridge_vsc >= 1 && op == 0xfd48) {
			shim_hit(h, SR_FD48, op, "create multi-adv instance answered here, status 0x01 (no multi-adv)");
			bridge_local_cc(h, op, 0x01, NULL, 0);
			return;
		}
		if (vendor && !bridge_fwd && (qca_reserved(op) || bridge_vsc >= 2)) {
			/* Broadcom/Apple vendor command: answer it, log it, learn it */
			if (qca_reserved(op))
				shim_hit(h, SR_QCA_GUARD, op, "is a QCA opcode on the WCN3998: answered here, not forwarded");
			else
				shim_hit(h, SR_VSC_ALL, op, "vendor command answered here, status 0 (BTD_VSC=2)");
			hci_log(h, "BTD BRIDGE: host vendor command 0x%04x plen %u (not forwarded)\n", op, cp->data[2]);
			bridge_fake_cc(h, op);
			return;
		}
		if (vendor) {
			shim_hit(h, SR_VSC_FWD, op, "vendor command forwarded to the WCN3998 (BTD_VSC=2 answers them here)");
			hci_log(h, "BTD BRIDGE: host vendor command 0x%04x plen %u forwarded\n", op, cp->data[2]);
		}
	}
	/* standard HCI (and, with --bridge-forward-vendor, vendor too): to the controller */
	if (hci_send(h, cp->type, cp->data, cp->got, 0))
		hci_log(h, "BTD BRIDGE: forward to controller failed\n");
}

static int bridge_dev(struct hci *h, const char *path, int fwd)
{
	bridge_fwd = fwd;
	bridge_fd = open(path, O_RDWR | O_NONBLOCK);
	if (bridge_fd < 0) {
		fail(h, "bridge-open", strerror(errno));
		return -1;
	}
	h->tap = bridge_tap;
	h->on_async = NULL;
	{
		/* in-band sleep: the NVM has it off (tag 17 bit 7, tag 27 bit 0 cleared as in --scan), yet this
		   WCN3998 still sends 0xFE when idle and 0xFD before it answers (r57a: bluetoothd's first command
		   came 8.5 s after the bring-up). 0xFD is always acknowledged with 0xFC (hci.c); BTD_IBS=1 (default)
		   also sends 0xFD and waits for 0xFC before a packet when the controller last said 0xFE. */
		const char *e = getenv("BTD_IBS");
		h->ibs = !(e && e[0] == '0');
		hci_log(h, "BTD BRIDGE: in-band sleep: NVM %s; controller 0xFD answered with 0xFC; wake (0xFD) before TX "
			"when asleep %s (BTD_IBS=%d); 0xFD/0xFE/0xFC never forwarded to the host\n",
			bridge_nvm_ibs ? "on (--ibs)" : "off", h->ibs ? "on" : "off", h->ibs);
	}
	{
		/* bluetool (the BlueTool stand-in) answers bluetoothd's "boot" once this names a live btd */
		FILE *rf = fopen(BTD_READY, "w");
		if (rf) {
			fprintf(rf, "%d\n", (int)getpid());
			fclose(rf);
			chmod(BTD_READY, 0644);
		}
	}
	hci_log(h, "BTD BRIDGE: %s <-> WCN3998; standard HCI forwarded, vendor 0xFC__ %s; shim BTD_VSC=%d%s\n", path,
		fwd ? "all forwarded" : bridge_vsc >= 2 ? "faked (Command Complete status 0) and logged"
		: "forwarded (QCA's 0xFC00/0B/48 answered here)", bridge_vsc, bridge_compat ? ", compat on" : ", compat off");
	{
		/* ws-y-bt diagnosis, once: XNU's poll() is kqueue; 1010's cdevsw has no cdevsw_setkqueueok, so
		   EVFILT_READ attach fails (filt_specattach EINVAL) and poll() reports POLLNVAL immediately */
		struct pollfd pf = { bridge_fd, POLLIN, 0 };
		int pr = poll(&pf, 1, 0);
		hci_log(h, "BTD BRIDGE: poll() probe -> %d revents 0x%x%s\n", pr, (unsigned)pf.revents,
			pr > 0 && (pf.revents & POLLNVAL) ? " (POLLNVAL: node not kqueue-ok; reading non-blocking + select())" : "");
	}
	struct h4 cp;
	memset(&cp, 0, sizeof(cp));
	uint8_t b[1024];
	int use_select = 1;
	for (;;) {
		int busy = 0;
		/* host -> controller: always try a read (O_NONBLOCK: EAGAIN when the h2b ring is empty) */
		ssize_t n = read(bridge_fd, b, sizeof(b));
		if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
			hci_log(h, "BTD BRIDGE: read %s: %s\n", path, strerror(errno));
			break;
		}
		if (n > 0) {
			if (bridge_host_bytes == 0)
				hci_log(h, "BTD BRIDGE: first %zd bytes from the host (bluetoothd)\n", n);
			bridge_host_bytes += (unsigned long)n;
			busy = 1;
			for (ssize_t i = 0; i < n; i++) {
				uint8_t c = b[i];
				int r = h4_feed(&cp, &c);
				if (r == 1)
					bridge_host_pkt(h, &cp);
				else if (r >= 2)
					hci_log(h, "BTD BRIDGE: host stray byte 0x%02x\n", c);
			}
		}
		struct hci_pkt p;		/* controller -> host goes through bridge_tap inside hci_recv */
		while (hci_recv(h, &p, 0) > 0)
			busy = 1;
		if (busy)
			continue;
		/* idle: sleep up to 1 ms, woken early by host bytes (select() uses d_select, which 1010 has) */
		if (use_select) {
			fd_set rs;
			FD_ZERO(&rs);
			FD_SET(bridge_fd, &rs);
			struct timeval tv = { 0, 1000 };
			if (select(bridge_fd + 1, &rs, NULL, NULL, &tv) < 0 && errno != EINTR) {
				hci_log(h, "BTD BRIDGE: select: %s; sleeping 1 ms per pass instead\n", strerror(errno));
				use_select = 0;
			}
		} else {
			usleep(1000);
		}
	}
	close(bridge_fd);
	bridge_fd = -1;
	unlink(BTD_READY);
	hci_log(h, "BTD BRIDGE: %lu host bytes, %lu host packets, %lu controller packets, %u vendor commands faked, "
		"%u answers fixed\n", bridge_host_bytes, bridge_host_pkts, bridge_ctrl_pkts, bridge_fake, bridge_fixed);
	hci_log(h, "BTD BRIDGE: in-band sleep bytes kept from the host: %lu wake ind 0xFD, %lu sleep ind 0xFE, %lu wake "
		"ack 0xFC; %lu 0xFC sent to the WCN3998, %lu 0xFD sent before TX\n", bridge_ibs_dropped[0],
		bridge_ibs_dropped[1], bridge_ibs_dropped[2], h->n_wake_ack, h->n_wake_tx);
	for (int r = 0; r < SR_N; r++)
		if (sr_hits[r])
			hci_log(h, "BTD SHIM: rule %s used %u times\n", sr_name[r], sr_hits[r]);
	return 0;
}

/* ---- bring-up ---- */

static int bring_up(struct hci *h, struct opts *o)
{
	struct qca_ver v;
	int r = -1;
	if (!o->noinit) {
		/* twice as Linux retries; then, unless --os was given, once more with the other UART oversampling
		   (lito's QUP: Linux mainline would pick 16 from the QUP version, the redbull kernel always 32) */
		for (int attempt = 0; attempt < 3 && r; attempt++) {
			if (attempt == 2) {
				if (o->os || !h->u->set_os)
					break;
				int os = h->u->os == 16 ? 32 : 16;
				hci_log(h, "BTD: trying UART oversampling %d instead of %d\n", os, h->u->os);
				if (h->u->set_os(h->u, os))
					break;
			}
			if (qca_power_pulses(h)) {
				fail(h, "pulse", "the UART could not send the power pulse");
				return -1;
			}
			r = qca_read_version(h, &v, 3000);
			if (r)
				hci_log(h, "BTD: no EDL version answer (%d)\n", r);
		}
		if (r) {
			fail(h, "version", "no answer to the EDL version request at 115200: chip unpowered (rails, "
				"SW_CTRL), pins/flow control wrong, or the power pulse not decoded");
			return -1;
		}
		hci_log(h, "BTD PROBE: SoC 0x%08x ROM 0x%04x patch 0x%04x product 0x%08x (UART oversampling %d, backend %s)\n",
			v.soc_id, v.rom_ver, v.patch_ver, v.product_id, h->u->os, h->u->name);
		if (o->mode == 'p')
			return 0;
	}
	int bidx = qca_baud_index(o->baud);
	if (o->baud != 115200 && !o->noinit) {
		if (bidx < 0 || bidx > 17 || qca_set_speed(h, o->baud)) {
			fail(h, "baud", "baud change failed (host clock?)");
			return -1;
		}
		struct qca_ver v2;
		if (qca_read_version(h, &v2, 2000)) {
			fail(h, "baud-verify", "no EDL answer after the baud change: retry with --baud 115200 (or --os)");
			return -1;
		}
	} else if (o->noinit && o->baud != 115200) {
		h->u->set_baud(h->u, o->baud);
	}
	if (!o->noinit) {
		char fw[512], nvm[512];
		unsigned rv = qca_rom_ver(v.soc_id, v.rom_ver), segs;
		snprintf(fw, sizeof(fw), "%s/crbtfw%02x.tlv", o->fwdir, rv);
		snprintf(nvm, sizeof(nvm), "%s/crnv%02x%s.bin", o->fwdir, rv, v.soc_id == QCA_WCN3991_SOC_ID ? "u" : "");
		struct nvm_opts no = { o->ibs, o->nvm_keep, o->nvm_pos };
		if (qca_download(h, o->fw ? o->fw : fw, &v, bidx, &no, &segs)) {
			fail(h, "rampatch", "rampatch download failed (file missing, or a TLV result error: wrong file "
				"for this ROM)");
			return -1;
		}
		usleep(10000);
		if (qca_download(h, o->nvm ? o->nvm : nvm, &v, bidx, &no, &segs)) {
			fail(h, "nvm", "NVM download failed");
			return -1;
		}
		h->ibs = o->ibs;
		if (hci_cmd(h, 0x0c03, NULL, 0, NULL, NULL, 5000)) {
			fail(h, "reset", "HCI_Reset after the download got no Command Complete (patch crashed the "
				"controller, or the NVM's baud differs from --baud)");
			return -1;
		}
	}
	int manu = qca_local_version(h);
	if (manu < 0) {
		fail(h, "version", "Read_Local_Version failed");
		return -1;
	}
	uint8_t addr[6] = { 0 };
	if (!o->setaddr) {
		if (qca_read_bdaddr(h, addr))
			hci_log(h, "BTD: Read_BD_ADDR failed\n");
	} else {
		if (o->have_addr)
			memcpy(addr, o->addr, 6);
		else if (adt_addr(addr)) {
			static const uint8_t def[6] = { 0x02, 0x50, 0x49, 0x58, 0x45, 0x4d };
			memcpy(addr, def, 6);
			hci_log(h, "BTD: no mac-address-bluetooth0 in the ADT; using the mkadt.py default\n");
		}
		if (qca_set_bdaddr(h, addr, v.cc_style))
			hci_log(h, "BTD: warning: BD address not changed\n");
	}
	/* the controller must still answer; if not, find out at which speed it does */
	if (qca_local_version(h) < 0) {
		fail(h, "after-up", "the controller stopped answering after the bring-up");
		qca_baud_probe(h);
		return -1;
	}
	hci_log(h, "BTD UP: manufacturer %d, %u Bd, BD_ADDR %02x:%02x:%02x:%02x:%02x:%02x, backend %s\n", manu,
		h->u->baud, addr[0], addr[1], addr[2], addr[3], addr[4], addr[5], h->u->name);
	return 0;
}

int main(int argc, char **argv)
{
	struct opts o;
	memset(&o, 0, sizeof(o));
	o.secs = 5;
	o.port = 2225;
	o.baud = 3000000;
	o.verbose = 1;
	o.fwdir = "/private/var/local/fw";
	o.nvm_pos = -1;
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		int more = i + 1 < argc && argv[i + 1][0] != '-';
		if (!strcmp(a, "--probe"))
			o.mode = 'p';
		else if (!strcmp(a, "--up"))
			o.mode = 'u';
		else if (!strcmp(a, "--scan")) {
			o.mode = 's';
			if (more)
				o.secs = (unsigned)atoi(argv[++i]);
		} else if (!strcmp(a, "--raw")) {
			o.mode = 'r';
			if (more)
				o.port = (unsigned)atoi(argv[++i]);
		} else if (!strcmp(a, "--bridge")) {
			o.mode = 'b';
			if (more)
				o.bridge_dev_path = argv[++i];
		} else if (!strcmp(a, "--bridge-raw")) {
			bridge_compat = 0;
		} else if (!strcmp(a, "--bridge-forward-vendor")) {
			o.fwd_vendor = 1;
		} else if (!strcmp(a, "--bridge-vsc") && more) {
			o.vsc = atoi(argv[++i]);
			if (o.vsc < 0 || o.vsc > 2)
				usage();
			o.vsc++;	/* 0 = not given */
		} else if (!strcmp(a, "--baud") && more)
			o.baud = (unsigned)atoi(argv[++i]);
		else if (!strcmp(a, "--os") && more)
			o.os = atoi(argv[++i]);
		else if (!strcmp(a, "--pmem"))
			o.pmem = 1;
		else if (!strcmp(a, "--fwdir") && more)
			o.fwdir = argv[++i];
		else if (!strcmp(a, "--fw") && more)
			o.fw = argv[++i];
		else if (!strcmp(a, "--nvm") && more)
			o.nvm = argv[++i];
		else if (!strcmp(a, "--setaddr"))
			o.setaddr = 1;
		else if (!strcmp(a, "--nvm-keep"))
			o.nvm_keep = 1;
		else if (!strcmp(a, "--nvm-baud-pos") && more)
			o.nvm_pos = atoi(argv[++i]);
		else if (!strcmp(a, "--ibs"))
			o.ibs = 1;
		else if (!strcmp(a, "--noinit"))
			o.noinit = 1;
		else if (!strcmp(a, "--bdaddr") && more) {
			if (parse_addr(argv[++i], o.addr))
				usage();
			o.have_addr = o.setaddr = 1;
		} else if (!strcmp(a, "-v"))
			o.verbose = 2;
		else if (!strcmp(a, "-q"))
			o.verbose = 0;
		else
			usage();
	}
	if (!o.mode || (o.os && o.os != 16 && o.os != 32) || qca_baud_index(o.baud) < 0)
		usage();
	setvbuf(stdout, NULL, _IOLBF, 0);
	signal(SIGPIPE, SIG_IGN);
	if (o.mode == 'b') {
		const char *env = getenv("BTD_VSC");
		if (o.vsc)
			bridge_vsc = o.vsc - 1;
		else if (env && env[0] >= '0' && env[0] <= '2' && !env[1])
			bridge_vsc = env[0] - '0';
		/* no bridge node (kernel without 1010 / boot-arg btbridge=1): say so before touching the radio and
		   exit 0, so launchd's KeepAlive {SuccessfulExit false} does not rerun the whole bring-up every 10 s */
		const char *bp = o.bridge_dev_path ? o.bridge_dev_path : "/dev/btbridge";
		struct stat st;
		if (stat(bp, &st) != 0) {
			printf("BTD FAIL bridge-open: %s: %s (kernel without 1010 or no btbridge=1 boot-arg); radio not "
			       "touched, exit 0\n", bp, strerror(errno));
			return 0;
		}
	}

	if (bt_rails_on(o.verbose)) {
		fail(NULL, "rails", "an RPMh vote failed (kernel without PMEM_RPMH, or the resource is not in cmd-db)");
		return 1;
	}
	struct uart *u = o.pmem ? NULL : btuart_open(o.verbose);
	if (!u)
		u = geni_open(o.verbose, o.os);
	if (!u) {
		fail(NULL, "uart", "SE5 not usable (see the line above: clocks, or no UART firmware in SE5)");
		return 1;
	}
	printf("btd: backend %s\n", u->name);
	struct hci h;
	hci_init(&h, u, o.verbose);
	int rc = bring_up(&h, &o);
	if (!rc && o.mode == 's') {
		rc = le_scan(&h, o.secs);
		rc = rc < 0 ? 1 : rc ? 3 : 0;	/* 3: up, but no advertisement seen */
	}
	else if (!rc && o.mode == 'r')
		rc = raw_bridge(&h, o.port);
	else if (!rc && o.mode == 'b')
		bridge_nvm_ibs = o.ibs, rc = bridge_dev(&h, o.bridge_dev_path ? o.bridge_dev_path : "/dev/btbridge", o.fwd_vendor);
	hci_log(&h, "BTD: %lu packets out, %lu in, %lu junk bytes, %lu IBS bytes, %lu hardware errors\n", h.n_tx,
		h.n_rx, h.n_junk, h.n_ibs, h.n_hwerr);
	if (h.n_wake_ack || h.n_wake_tx)
		hci_log(&h, "BTD: in-band sleep: %lu wake acknowledgements (0xFC) sent, %lu wake indications (0xFD) sent\n",
			h.n_wake_ack, h.n_wake_tx);
	u->close(u);
	return rc == 3 ? 3 : rc ? 1 : 0;
}
