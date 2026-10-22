/*
 * /dev/wlan: the kernel's Wi-Fi station (bsd/dev/flame_wlan.c, under en0 and wifid's Apple80211 requests,
 * ios-topaz 0900's redwood code) and the radio, which runs in userland (phone/wifi: wland). The same file is
 * the kernel's bsd/sys/flame_wlan.h.
 *
 * One message per read() or write(): a header, then `len` bytes. wland opens the device once the radio is up,
 * says HELLO, and from then on reads the kernel's requests (non-blocking) and writes what happened.
 */
#ifndef FLAMEWLAN_H
#define FLAMEWLAN_H
#include <stdint.h>

struct fw_hdr {
	uint16_t type;
	uint16_t len;			/* of the payload after the header */
};

enum {
	/* kernel -> wland */
	FW_SCAN = 1,			/* no payload: scan, then BSS_BEGIN, BSS..., SCAN_DONE */
	FW_JOIN = 2,			/* struct fw_join; JOIN_DONE when frames can pass or why not */
	FW_LEAVE = 3,			/* no payload; LEFT */
	FW_TX = 4,			/* an Ethernet frame (destination, source, type, payload) */

	/* wland -> kernel */
	FW_HELLO = 16,			/* struct fw_hello: the radio is up */
	FW_BSS_BEGIN = 17,		/* no payload: a new list of what was heard follows */
	FW_BSS = 18,			/* struct fw_bss */
	FW_SCAN_DONE = 19,		/* int32_t: 0 or an errno */
	FW_JOIN_DONE = 20,		/* int32_t: 0 or an errno */
	FW_LEFT = 21,			/* int32_t */
	FW_LINK = 22,			/* struct fw_link: frames can pass now (up), or no longer (left or lost) */
	FW_RX = 23,			/* an Ethernet frame */
};

#define FW_FRAME_MAX	1514
#define FW_MSG_MAX	(sizeof(struct fw_hdr) + 1600)

struct fw_hello {
	uint8_t address[6];
};

enum { FW_KEY_NONE, FW_KEY_PASSPHRASE, FW_KEY_PMK };

struct fw_join {
	uint8_t ssid[32], ssid_len;
	uint8_t bssid[6], any_bssid;	/* any_bssid: the access point of that name heard best */
	uint8_t key_kind, key_len;	/* FW_KEY_*: the passphrase (8-63 bytes) or the 32-byte PMK */
	uint8_t key[64];
};

struct fw_link {
	uint8_t up;
	uint8_t ssid[32], ssid_len;	/* the network joined (also when wland joined it by itself: wlan.conf) */
	uint8_t bssid[6];
};

struct fw_bss {
	uint8_t bssid[6];
	uint8_t ssid[32], ssid_len;
	uint16_t frequency;		/* MHz */
	int16_t rssi;			/* dBm */
	uint16_t beacon_interval, capability;
	uint32_t age_ms;
	uint16_t elements_len;
	uint8_t elements[768];		/* the beacon's information elements */
};

#endif
