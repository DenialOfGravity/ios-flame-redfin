/*
 * The kernel's Wi-Fi station over /dev/wlan (flamewlan.h; the kernel side is bsd/dev/flame_wlan.c, under en0
 * and wifid's Apple80211 requests): wifid's scans and joins come here as requests, en0's frames both ways.
 * In this mode iOS does the IP side itself on en0 (configd, DHCP), so ipnet.c's utun is not made. Without the
 * device (an older kernel, or boot-arg sweetwifid=0) wland keeps its own utun.
 */
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "flamewlan.h"
#include "link.h"
#include "radio.h"
#include "bridge.h"

static int bfd = -1;
static int hello_sent;
static int scan_pending, join_pending;
static unsigned scans_at;
static uint64_t scan_deadline, join_deadline, last_bg_scan;
/*
 * redfin 2026-10-28: a failed join of wifid's (the network not in the list yet, the AP refusing or not answering)
 * is tried again here, up to JOIN_RETRIES times while wifid's join is still open, before wifid hears of it:
 * wifid's own retry of an auto-join comes ~28 s later. The key stays only for the retries.
 */
#define JOIN_RETRIES	2
static char join_ssid[33], join_pass[65];
static int join_retries;
static unsigned join_scans_at;
static uint64_t join_retry_at;
static int rssi_off;			/* the kernel refused FW_RSSI (a kernel without 1014): not sent again */
static uint64_t rssi_next, rssi_sent_ms;
static int rssi_sent = 1000;

static void join_forget(void)
{
	memset(join_pass, 0, sizeof(join_pass));
	join_retries = 0;
	join_retry_at = 0;
}
int bridge_joins;	/* wifid has asked for a network (or to leave): wland's own wlan.conf join stands down */

/* 0 or the errno of the write */
static int bridge_send(uint16_t type, const void *data, size_t len)
{
	uint8_t m[FW_MSG_MAX];
	struct fw_hdr h = { type, (uint16_t)len };
	if (bfd < 0 || len > sizeof(m) - sizeof(h))
		return EINVAL;
	memcpy(m, &h, sizeof(h));
	if (len)
		memcpy(m + sizeof(h), data, len);
	if (write(bfd, m, sizeof(h) + len) < 0) {
		int e = errno;
		if (type != FW_RX && type != FW_RSSI)
			printf("[%6llu] bridge: write type %u: %s\n", (unsigned long long)link_ms(), type, strerror(e));
		return e;
	}
	return 0;
}

static void bridge_status(uint16_t type, int32_t status)
{
	bridge_send(type, &status, sizeof(status));
}

static void bridge_rx(const uint8_t *frame, uint32_t len)
{
	if (len <= FW_FRAME_MAX)
		bridge_send(FW_RX, frame, len);
}

static void bridge_link(int up)
{
	struct fw_link l;
	memset(&l, 0, sizeof(l));
	l.up = (uint8_t)(up != 0);
	l.ssid_len = (uint8_t)radio_ssid(l.ssid, l.bssid);
	printf("[%6llu] bridge: link %s '%.*s'\n", (unsigned long long)link_ms(), up ? "up" : "down", l.ssid_len, l.ssid);
	bridge_send(FW_LINK, &l, sizeof(l));
}

/* what the scans heard (in the last minute), then SCAN_DONE */
static void bridge_list(int32_t status)
{
	static struct radio_bss r;
	static struct fw_bss b;
	unsigned n = 0;
	bridge_send(FW_BSS_BEGIN, NULL, 0);
	for (unsigned i = 0; radio_heard(i, &r) == 0; i++) {
		if (r.age_ms > 120000)
			continue;			/* not heard in the last two minutes */
		memset(&b, 0, sizeof(b));
		memcpy(b.bssid, r.bssid, 6);
		memcpy(b.ssid, r.ssid, r.ssid_len);
		b.ssid_len = r.ssid_len;
		b.frequency = r.freq;
		b.rssi = r.rssi;
		b.beacon_interval = r.bintval;
		b.capability = r.capab;
		b.age_ms = r.age_ms;
		b.elements_len = r.ie_len;
		memcpy(b.elements, r.ie, r.ie_len);
		bridge_send(FW_BSS, &b, sizeof(b));
		n++;
	}
	bridge_status(FW_SCAN_DONE, status);
	printf("[%6llu] bridge: scan done, %u networks for wifid\n", (unsigned long long)link_ms(), n);
}

int bridge_open(void)
{
	bfd = open("/dev/wlan", O_RDWR | O_NONBLOCK);
	if (bfd < 0) {
		printf("bridge: no /dev/wlan (%s): wland's own utun\n", strerror(errno));
		return -1;
	}
	radio_rx_hook = bridge_rx;
	radio_link_hook = bridge_link;
	printf("bridge: /dev/wlan open: en0 and wifid\n");
	return 0;
}

static void on_join(const struct fw_join *j)
{
	char pass[65] = "";
	char ssid[33];
	uint8_t cur[32];
	unsigned cl = radio_ssid(cur, NULL);
	bridge_joins = 1;
	memcpy(ssid, j->ssid, j->ssid_len);
	ssid[j->ssid_len] = 0;
	if (radio_joined() && cl == j->ssid_len && !memcmp(cur, j->ssid, cl)) {
		printf("[%6llu] bridge: join '%s': joined already\n", (unsigned long long)link_ms(), ssid);
		bridge_status(FW_JOIN_DONE, 0);
		bridge_link(1);
		return;
	}
	if (j->key_kind == FW_KEY_PASSPHRASE && j->key_len >= 8 && j->key_len <= 63) {
		memcpy(pass, j->key, j->key_len);
		pass[j->key_len] = 0;
	} else if (j->key_kind == FW_KEY_PMK && j->key_len == 32) {
		for (int i = 0; i < 32; i++)
			snprintf(pass + 2 * i, 3, "%02x", j->key[i]);	/* radio_join takes the PMK as 64 hex digits */
	}
	if (radio_joined())
		radio_disconnect();
	join_forget();
	snprintf(join_ssid, sizeof(join_ssid), "%s", ssid);
	snprintf(join_pass, sizeof(join_pass), "%s", pass);
	int r = radio_join(ssid, pass);
	memset(pass, 0, sizeof(pass));
	printf("[%6llu] bridge: join '%s' (%s) -> %d\n", (unsigned long long)link_ms(), ssid,
	       j->key_kind == FW_KEY_PMK ? "PMK" : j->key_kind == FW_KEY_PASSPHRASE ? "passphrase" : "open", r);
	if (r) {
		join_forget();
		bridge_status(FW_JOIN_DONE, r);
		return;
	}
	join_pending = 1;
	join_deadline = link_ms() + 35000;
}

/*
 * configd writes its default network configuration only when it starts without preferences.plist,
 * and it starts long before the first scan makes en0: that default has no network services, so
 * iOS never runs DHCP on en0 (frames come in, none go out). Once en0 exists: if preferences.plist
 * has no NetworkServices, move it aside and restart configd (launchd starts it again), which then
 * creates the Wi-Fi service for en0. Once per wland run; the new file persists across boots.
 * (flame 2026-10-22 did this by hand; redfin 2026-10-24.)
 */
#define SC_PREFS	"/private/var/preferences/SystemConfiguration/preferences.plist"
static uint64_t sc_check_at;

static int sc_has_services(void)
{
	FILE *f = fopen(SC_PREFS, "rb");
	if (!f)
		return -1;
	static char b[65536];
	size_t n = fread(b, 1, sizeof(b), f);
	fclose(f);
	for (size_t i = 0; i + 15 <= n; i++)		/* binary or XML plist: the key is stored as text */
		if (!memcmp(b + i, "NetworkServices", 15))
			return 1;
	return 0;
}

static void sc_fix(void)
{
	int has = sc_has_services();
	if (has != 0) {
		printf("[%6llu] bridge: configd preferences %s\n", (unsigned long long)link_ms(),
		       has > 0 ? "have network services" : "absent (configd writes them)");
		return;
	}
	if (rename(SC_PREFS, SC_PREFS ".pre-wifi")) {
		printf("bridge: configd preferences: rename failed (%s)\n", strerror(errno));
		return;
	}
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;
	int killed = 0;
	if (sysctl(mib, 3, NULL, &len, NULL, 0) == 0 && len) {
		len += 16 * sizeof(struct kinfo_proc);
		struct kinfo_proc *kp = malloc(len);
		if (kp && sysctl(mib, 3, kp, &len, NULL, 0) == 0) {
			for (size_t i = 0; i < len / sizeof(*kp); i++)
				if (!strcmp(kp[i].kp_proc.p_comm, "configd") && kill(kp[i].kp_proc.p_pid, SIGTERM) == 0)
					killed++;
		}
		free(kp);
	}
	printf("[%6llu] bridge: configd preferences had no network services: moved to .pre-wifi, "
	       "configd restarted (%d)\n", (unsigned long long)link_ms(), killed);
}

/* from wland's idle loop */
void bridge_poll(void)
{
	static uint8_t m[FW_MSG_MAX];
	if (bfd < 0)
		return;
	if (!hello_sent && radio_scans() > 0) {
		struct fw_hello h;
		memcpy(h.address, radio_mac, 6);
		bridge_send(FW_HELLO, &h, sizeof(h));
		hello_sent = 1;
		printf("[%6llu] bridge: hello: the kernel makes en0\n", (unsigned long long)link_ms());
		sc_check_at = link_ms() + 5000;
	}
	if (sc_check_at && link_ms() >= sc_check_at) {
		sc_check_at = 0;
		sc_fix();
	}
	for (int n = 0; n < 32; n++) {
		ssize_t r = read(bfd, m, sizeof(m));
		if (r < (ssize_t)sizeof(struct fw_hdr))
			break;
		struct fw_hdr h;
		memcpy(&h, m, sizeof(h));
		const uint8_t *p = m + sizeof(h);
		switch (h.type) {
		case FW_SCAN:
			if (scan_pending)
				break;			/* the scan under way answers it */
			if (radio_joined() && link_ms() - last_bg_scan < 15000) {
				bridge_list(0);		/* joined: a background scan at most every 15 s; what is known */
				break;
			}
			scan_pending = 1;
			scans_at = radio_scans();
			scan_deadline = link_ms() + (radio_joined() ? 25000 : 12000);
			if (radio_joined()) {
				last_bg_scan = link_ms();
				radio_scan_now();
			} else {
				radio_rescan(0);
			}
			break;
		case FW_JOIN:
			join_pending = 0;
			join_forget();
			if (h.len >= sizeof(struct fw_join))
				on_join((const struct fw_join *)p);
			else
				bridge_status(FW_JOIN_DONE, EINVAL);
			break;
		case FW_LEAVE:
			bridge_joins = 1;
			join_pending = 0;
			join_forget();
			printf("[%6llu] bridge: leave\n", (unsigned long long)link_ms());
			radio_disconnect();
			bridge_status(FW_LEFT, 0);
			break;
		case FW_TX:
			radio_tx_ether(p, h.len);
			break;
		default:
			break;
		}
	}
	uint64_t now = link_ms();
	if (scan_pending && (radio_scans() > scans_at || now > scan_deadline)) {
		scan_pending = 0;
		bridge_list(0);			/* (after the deadline: what is known so far) */
	}
	if (join_pending && join_retry_at) {
		/* a retry waits for its moment (and, for a network not heard, a scan that has finished) */
		if (now >= join_retry_at && (join_scans_at == 0 || radio_scans() > join_scans_at || now > join_retry_at + 8000)) {
			join_retry_at = 0;
			int r = radio_join(join_ssid, join_pass);
			printf("[%6llu] bridge: join '%s' again (retry %d) -> %d\n", (unsigned long long)now, join_ssid,
			       join_retries, r);
			if (r) {
				join_pending = 0;
				join_forget();
				bridge_status(FW_JOIN_DONE, r);
			}
		}
	} else if (join_pending) {
		int r = radio_join_result();
		int again = (r == ENOENT || r == ECONNREFUSED || r == ETIMEDOUT || r == EIO) && join_retries < JOIN_RETRIES &&
			    now + 12000 < join_deadline;
		if (r != -1 && again) {
			join_retries++;
			join_scans_at = 0;
			join_retry_at = now + 500;
			if (r == ENOENT) {			/* not in the list: a fresh scan first */
				join_scans_at = radio_scans();
				radio_rescan(0);
			}
			printf("[%6llu] bridge: join '%s' failed (%s): trying again (%d/%d)\n", (unsigned long long)now,
			       join_ssid, strerror(r), join_retries, JOIN_RETRIES);
		} else if (r != -1 || now > join_deadline) {
			join_pending = 0;
			join_forget();
			bridge_status(FW_JOIN_DONE, r == -1 ? ETIMEDOUT : r);
		}
	}
	/* the joined network's signal for the status bar (kernel 1014): every 2 s when it moved 2 dB, else every 10 s */
	if (!rssi_off && now >= rssi_next) {
		int rssi;
		uint32_t age;
		rssi_next = now + 2000;
		if (radio_link_rssi(&rssi, &age) == 0 && (abs(rssi - rssi_sent) >= 2 || now - rssi_sent_ms >= 10000)) {
			struct fw_rssi q;
			memset(&q, 0, sizeof(q));
			q.rssi = (int16_t)rssi;
			radio_ssid((uint8_t[32]){ 0 }, q.bssid);
			q.age_s = (uint16_t)(age / 1000 > 0xffffu ? 0xffffu : age / 1000);
			int e = bridge_send(FW_RSSI, &q, sizeof(q));
			if (e == EINVAL) {
				rssi_off = 1;
				printf("[%6llu] bridge: the kernel takes no signal reports (no 1014)\n", (unsigned long long)now);
			} else if (!e) {
				rssi_sent = rssi;
				rssi_sent_ms = now;
			}
		} else if (!radio_joined()) {
			rssi_sent = 1000;
		}
	}
}

int bridge_active(void)
{
	return bfd >= 0;
}
