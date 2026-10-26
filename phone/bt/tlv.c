#include <stdio.h>
#include <string.h>
#include "tlv.h"

static uint32_t le32(const uint8_t *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t le16(const uint8_t *p)
{
	return (uint16_t)(p[0] | p[1] << 8);
}

int tlv_parse(const uint8_t *buf, size_t n, struct tlv_info *ti, const char **err)
{
	const char *dummy;
	if (!err)
		err = &dummy;
	memset(ti, 0, sizeof(*ti));
	ti->type = -1;
	ti->hci_tag_len = -1;
	if (n < 4) {
		*err = "shorter than a TLV header";
		return -1;
	}
	uint32_t tl = le32(buf);
	ti->length = tl >> 8;
	if ((size_t)ti->length + 4 > n) {
		*err = "header length beyond the end of the file";
		return -1;
	}
	switch (tl & 0xff) {
	case TLV_TYPE_PATCH:
		if (ti->length < 24) {
			*err = "patch header truncated";
			return -1;
		}
		ti->type = TLV_TYPE_PATCH;
		ti->total_size = le32(buf + 4);
		ti->data_length = le32(buf + 8);
		ti->format_version = buf[12];
		ti->signature = buf[13];
		ti->dnld_mode = buf[14];
		ti->product_id = le16(buf + 16);
		ti->rom_build = le16(buf + 18);
		ti->patch_version = le16(buf + 20);
		ti->entry = le32(buf + 24);
		return 0;
	case TLV_TYPE_NVM:
	case 4: {
		/* Type 2: the 12-byte tags follow the header. Type 4 (redfin's crnv32.bin, crnv32u.bin): a
		 * wrapper whose first 4 bytes are a nested type-2 header (type in the low byte, length above),
		 * then the tags, then 0xff padding to the outer length. Linux's btqca.c dispatches on the
		 * caller's type and only logs the file's, so both download as they are. */
		ti->type = TLV_TYPE_NVM;
		ti->nvm_off = 4;
		ti->nvm_len = ti->length;
		if ((tl & 0xff) == 4) {
			if (ti->length < 4 || (le32(buf + 4) & 0xff) != TLV_TYPE_NVM) {
				*err = "type 4 without a nested NVM header";
				return -1;
			}
			ti->nvm_off = 8;
			ti->nvm_len = le32(buf + 4) >> 8;
			if (ti->nvm_len + 4 > ti->length) {
				*err = "nested NVM length beyond the outer one";
				return -1;
			}
		}
		const uint8_t *d = buf + ti->nvm_off;
		uint32_t idx = 0;
		while (idx < ti->nvm_len) {
			if (idx + 12 > ti->nvm_len) {
				*err = "NVM tag header crosses the end";
				return -1;
			}
			uint16_t id = le16(d + idx), len = le16(d + idx + 2);
			if (id == 0xffff)
				break;		/* padding */
			if (idx + 12 + len > ti->nvm_len) {
				*err = "NVM tag data crosses the end";
				return -1;
			}
			if (id == TLV_TAG_HCI)
				ti->hci_tag_len = len;
			ti->ntags++;
			idx += 12 + len;
		}
		return 0;
	}
	default:
		*err = "unknown TLV type";
		return -1;
	}
}

static int setbyte(uint8_t *p, uint8_t v)
{
	if (*p == v)
		return 0;
	*p = v;
	return 1;
}

int tlv_nvm_edit(uint8_t *buf, size_t n, int baud_idx, int baud_pos, int ibs, const uint8_t *bdaddr)
{
	struct tlv_info ti;
	if (tlv_parse(buf, n, &ti, NULL) || ti.type != TLV_TYPE_NVM)
		return -1;
	uint8_t *d = buf + ti.nvm_off;
	uint32_t idx = 0;
	int changed = 0;
	while (idx < ti.nvm_len) {
		uint16_t id = le16(d + idx), len = le16(d + idx + 2);
		if (id == 0xffff)
			break;
		uint8_t *data = d + idx + 12;
		switch (id) {
		case TLV_TAG_HCI:
			if (len >= 1)
				changed += setbyte(&data[0], ibs ? data[0] | 0x80 : data[0] & 0x7f);
			if (baud_idx >= 0 && baud_pos >= 0 && len > baud_pos)
				changed += setbyte(&data[baud_pos], (uint8_t)baud_idx);
			break;
		case TLV_TAG_DEEP_SLEEP:
			if (len >= 1)
				changed += setbyte(&data[0], ibs ? data[0] | 0x01 : data[0] & 0xfe);
			break;
		case TLV_TAG_BDADDR:
			if (bdaddr && len >= 6)
				for (int i = 0; i < 6; i++)
					changed += setbyte(&data[i], bdaddr[i]);
			break;
		}
		idx += 12 + len;
	}
	return changed;
}

size_t tlv_segments(size_t n, int dnld_mode, struct tlv_seg *out, size_t max)
{
	size_t count = 0, off = 0;
	int skip = dnld_mode == TLV_SKIP_VSE || dnld_mode == TLV_SKIP_VSE_CC;
	while (off < n) {
		size_t len = n - off < TLV_SEG_MAX ? n - off : TLV_SEG_MAX;
		int last = off + len == n || len < TLV_SEG_MAX;
		if (count < max) {
			out[count].off = (uint32_t)off;
			out[count].len = (uint32_t)len;
			out[count].want_ack = !skip || last;
		}
		count++;
		off += len;
	}
	return count;
}

unsigned qca_rom_ver(uint32_t soc_id, uint16_t rom_ver)
{
	uint32_t soc_ver = soc_id << 16 | rom_ver;
	return ((soc_ver & 0x00000f00) >> 4) | (soc_ver & 0x0000000f);
}

int tlv_nvm_tag_hex(const uint8_t *buf, size_t n, uint16_t id, char *out, size_t cap)
{
	struct tlv_info ti;
	snprintf(out, cap, "absent");
	if (tlv_parse(buf, n, &ti, NULL) || ti.type != TLV_TYPE_NVM)
		return -1;
	const uint8_t *d = buf + ti.nvm_off;
	uint32_t idx = 0;
	while (idx + 12 <= ti.nvm_len) {
		uint16_t tid = le16(d + idx), len = le16(d + idx + 2);
		if (tid == 0xffff)
			break;
		if (tid == id) {
			size_t o = 0;
			out[0] = 0;
			for (unsigned i = 0; i < len && o + 4 < cap; i++)
				o += (size_t)snprintf(out + o, cap - o, "%s%02x", i ? " " : "", d[idx + 12 + i]);
			return len;
		}
		idx += 12u + len;
	}
	return -1;
}
