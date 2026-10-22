/* QMI messages (Linux soc/qcom/qmi_encdec.c wire format) over QRTR. */
#ifndef QMI_H
#define QMI_H
#include <stdint.h>
#include <stddef.h>

#define QMI_REQUEST	0
#define QMI_RESPONSE	2
#define QMI_INDICATION	4

struct qmi_msg {
	uint8_t type;
	uint16_t txn, id;
	const uint8_t *tlv;	/* received: the TLV area */
	uint16_t len;
};

/* Building: a buffer with the 7-byte header, then TLVs. */
struct qmi_buf {
	uint8_t b[8192];	/* the largest WLFW request (BDF download) is 6182 + 7 */
	size_t n;
};
void qmi_start(struct qmi_buf *q, uint8_t type, uint16_t txn, uint16_t id);
void qmi_tlv(struct qmi_buf *q, uint8_t t, const void *v, uint16_t len);
void qmi_tlv_u8(struct qmi_buf *q, uint8_t t, uint8_t v);
void qmi_tlv_u32(struct qmi_buf *q, uint8_t t, uint32_t v);
void qmi_tlv_u64(struct qmi_buf *q, uint8_t t, uint64_t v);
void qmi_tlv_result(struct qmi_buf *q, uint16_t result, uint16_t error);	/* TLV 2 */
size_t qmi_finish(struct qmi_buf *q);		/* fills in the length; returns the size */

int qmi_parse(const uint8_t *d, uint32_t n, struct qmi_msg *m);
/* TLV t of a parsed message: pointer + length, NULL if absent. */
const uint8_t *qmi_get(const struct qmi_msg *m, uint8_t t, uint16_t *len);
int qmi_get_u32(const struct qmi_msg *m, uint8_t t, uint32_t *v);
int qmi_get_u8(const struct qmi_msg *m, uint8_t t, uint8_t *v);
void qmi_dump(const struct qmi_msg *m);

#endif
