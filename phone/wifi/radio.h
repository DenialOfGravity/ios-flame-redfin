#ifndef RADIO_H
#define RADIO_H
#include <stdint.h>

/* The WLAN DMA stream (apps SMMU 0x640/0x1) through a translation-off bank; before the modem boots. 0 = ok. */
int smmu_wlan_identity(void);
int radio_start(void);		/* after WLFW mission mode: copy engines, HTC, then WMI/HTT/scan from radio_poll */
void radio_poll(void);		/* called from the link's idle loop */
void radio_summary(void);	/* the networks heard so far */
void radio_stats(void);
unsigned radio_scans(void);	/* passive scans completed */
void radio_scan_now(void);	/* a scan as soon as it can, also while joined (a background scan) */
void radio_rescan(unsigned ms);	/* another passive scan in MS (while idle: not joining, not joined) */
extern const uint8_t radio_mac[6];

/* station: join SSID (passphrase, 64 hex digits = PMK, or "" for open); after the first scan */
int radio_join(const char *ssid, const char *pass);
int radio_join_result(void);	/* -1 while it runs, 0 joined, ENOTCONN joined then lost, else an errno */
void radio_disconnect(void);	/* drop a joined link (tests the rejoin) */
/* what scans heard, for wifid (flamewlan.c) */
struct radio_bss {
	uint8_t bssid[6], ssid[32], ssid_len;
	uint16_t freq, bintval, capab, ie_len;
	int16_t rssi;
	uint32_t age_ms;
	uint8_t ie[768];
};
int radio_heard(unsigned i, struct radio_bss *out);	/* 0, or -1 past the last */
int radio_scanning(void);	/* a scan runs or is due */
int radio_joined(void);
unsigned radio_ssid(uint8_t ssid[32], uint8_t bssid[6]);	/* of the network joined or being joined; 0 when idle */
int radio_tx_ether(const uint8_t *frame, uint32_t len);	/* an Ethernet frame out; 0 = queued */
extern void (*radio_rx_hook)(const uint8_t *frame, uint32_t len);	/* Ethernet frames in */
extern void (*radio_link_hook)(int up);

#endif
