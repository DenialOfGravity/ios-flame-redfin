/*
 * Qualcomm WCN399x bring-up over H4, after Linux drivers/bluetooth/btqca.c + hci_qca.c (GPL-2.0;
 * protocol only, no code copied): power pulses, EDL version, baud change, TLV download, BD address.
 */
#ifndef BT_QCA_H
#define BT_QCA_H
#include <stdint.h>
#include "hci.h"

#define QCA_WCN3991_SOC_ID	0x40014320u

struct qca_ver {
	uint32_t product_id;
	uint16_t patch_ver;
	uint16_t rom_ver;
	uint32_t soc_id;
	int cc_style;		/* the answer came in a Command Complete (WCN3991 and later) */
};

/* 0xC0 at 2400 Bd then 0xFC at 115200 Bd, each with flow control off; 100 ms boot time */
int qca_power_pulses(struct hci *h);
/* EDL_PATCH_VER_REQ (0xFC00 sub 0x19); 0 = ok */
int qca_read_version(struct hci *h, struct qca_ver *v, unsigned ms);
/* QCA_BAUDRATE_* index of a speed, -1 if none */
int qca_baud_index(unsigned baud);
/* tell the controller (raw 01 48 FC 01 idx, flow control off around it), then the host UART */
int qca_set_speed(struct hci *h, unsigned baud);
/*
 * Download one TLV file (rampatch or NVM; type from its header). NVM gets tlv_nvm_edit(baud_idx, ibs).
 * Returns 0 or -1; *segs = segments sent.
 */
int qca_download(struct hci *h, const char *path, const struct qca_ver *v, int baud_idx, int ibs, unsigned *segs);
/* addr in the usual written order (addr[0] is the most significant byte); 0 if Read_BD_ADDR agrees */
int qca_set_bdaddr(struct hci *h, const uint8_t addr[6]);
/* Read_Local_Version; returns the manufacturer (29 = Qualcomm) or -1 */
int qca_local_version(struct hci *h);
#endif
