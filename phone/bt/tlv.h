/*
 * QCA TLV firmware images (crbtfwNN.tlv rampatch, crnvNN.bin NVM) as btqca.c reads them:
 * pure functions, no I/O, unit-tested on the host (tlv_test.c).
 *
 *   header  u32 type_len: type in bits 7:0 (1 = patch, 2 = NVM), payload length in bits 31:8
 *   patch   u32 total_size, u32 data_length, u8 format_version, u8 signature, u8 download_mode,
 *           u8 reserved, u16 product_id, u16 rom_build, u16 patch_version, u16 reserved, u32 entry
 *   NVM     tags: u16 tag_id, u16 tag_len, u32 reserved, u32 reserved, u8 data[tag_len]
 *
 * The whole file (header included) goes to the controller in segments of at most 243 bytes, each one
 * HCI command 0xFC00 with parameters { 0x1E, len, bytes }.
 */
#ifndef BT_TLV_H
#define BT_TLV_H
#include <stddef.h>
#include <stdint.h>

#define TLV_TYPE_PATCH		1
#define TLV_TYPE_NVM		2
#define TLV_SEG_MAX		243	/* MAX_SIZE_PER_TLV_SEGMENT */
#define TLV_TAG_HCI		17	/* EDL_TAG_ID_HCI: [0] bit 7 in-band sleep, baud index at [2] ([1] on WCN3991+) */
#define TLV_TAG_DEEP_SLEEP	27	/* EDL_TAG_ID_DEEP_SLEEP: [0] bit 0 */
#define TLV_TAG_BDADDR		2

/* qca_tlv_dnld_mode: which per-segment events the controller leaves out */
#define TLV_SKIP_NONE		0	/* vendor event (and command complete) for every segment */
#define TLV_SKIP_VSE		1	/* command complete only: nothing to wait for */
#define TLV_SKIP_CC		2	/* vendor event only */
#define TLV_SKIP_VSE_CC		3	/* nothing until the last segment */

struct tlv_info {
	int type;			/* TLV_TYPE_* or -1 */
	uint32_t length;		/* payload length from the header */
	/* patch */
	uint32_t total_size, data_length;
	uint8_t format_version, signature, dnld_mode;
	uint16_t product_id, rom_build, patch_version;
	uint32_t entry;
	/* NVM */
	int ntags;
	int hci_tag_len;		/* -1: no tag 17 */
	uint32_t nvm_off, nvm_len;	/* NVM: where the 12-byte tags start in the file and how many bytes they span */
};

struct tlv_seg {
	uint32_t off;			/* offset in the file */
	uint32_t len;			/* 1..243 */
	int want_ack;			/* host waits for the TLV result event after this one */
};

/* 0 = understood (ti filled), -1 = not a TLV image this code knows; err gets a reason. */
int tlv_parse(const uint8_t *buf, size_t n, struct tlv_info *ti, const char **err);

/*
 * NVM edits before download (btqca.c qca_tlv_check_data does the first two unconditionally):
 *   tag 17 [0] bit 7 (software in-band sleep): set if ibs, else cleared
 *   tag 17 [baud_pos] = baud_idx              (baud_pos 2; 1 for WCN3991-style controllers; baud_idx < 0: keep)
 *   tag 27 [0] bit 0 (deep sleep): set if ibs, else cleared
 *   tag 2  = bdaddr (6 bytes, little endian as sent over HCI) if bdaddr != NULL and the tag exists
 * Returns the number of bytes changed (>= 0) or -1 if the tag list is malformed.
 */
int tlv_nvm_edit(uint8_t *buf, size_t n, int baud_idx, int baud_pos, int ibs, const uint8_t *bdaddr);

/*
 * Split an n-byte file into segments the way qca_download_firmware does: 243 bytes each, the rest last.
 * want_ack = 0 for dnld_mode VSE / VSE_CC, except the last (or any short) segment, which is always acked.
 * Returns the number of segments (also when larger than max: only max are written).
 */
size_t tlv_segments(size_t n, int dnld_mode, struct tlv_seg *out, size_t max);

/* the bytes of NVM tag id as hex into out ("absent" if none); returns the tag length or -1 */
int tlv_nvm_tag_hex(const uint8_t *buf, size_t n, uint16_t id, char *out, size_t cap);

/* btqca.c firmware naming: rom_ver = ((soc_ver & 0xf00) >> 4) | (soc_ver & 0xf), soc_ver = soc_id << 16 | rom */
unsigned qca_rom_ver(uint32_t soc_id, uint16_t rom_ver);

#endif
