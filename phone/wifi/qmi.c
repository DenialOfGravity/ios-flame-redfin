#include <stdio.h>
#include <string.h>
#include "qmi.h"

void qmi_start(struct qmi_buf *q, uint8_t type, uint16_t txn, uint16_t id)
{
	q->b[0] = type;
	memcpy(q->b + 1, &txn, 2);
	memcpy(q->b + 3, &id, 2);
	q->n = 7;
}

void qmi_tlv(struct qmi_buf *q, uint8_t t, const void *v, uint16_t len)
{
	if (q->n + 3 + len > sizeof(q->b)) {
		fprintf(stderr, "qmi: TLV %#x (%u bytes) does not fit: message dropped\n", t, len);
		q->n = sizeof(q->b) + 1;	/* qmi_finish fails */
		return;
	}
	q->b[q->n] = t;
	memcpy(q->b + q->n + 1, &len, 2);
	memcpy(q->b + q->n + 3, v, len);
	q->n += 3 + len;
}

void qmi_tlv_u8(struct qmi_buf *q, uint8_t t, uint8_t v) { qmi_tlv(q, t, &v, 1); }
void qmi_tlv_u32(struct qmi_buf *q, uint8_t t, uint32_t v) { qmi_tlv(q, t, &v, 4); }
void qmi_tlv_u64(struct qmi_buf *q, uint8_t t, uint64_t v) { qmi_tlv(q, t, &v, 8); }

void qmi_tlv_result(struct qmi_buf *q, uint16_t result, uint16_t error)
{
	uint16_t r[2] = { result, error };
	qmi_tlv(q, 2, r, 4);
}

size_t qmi_finish(struct qmi_buf *q)
{
	if (q->n > sizeof(q->b))
		return 0;
	uint16_t len = (uint16_t)(q->n - 7);
	memcpy(q->b + 5, &len, 2);
	return q->n;
}

int qmi_parse(const uint8_t *d, uint32_t n, struct qmi_msg *m)
{
	if (n < 7)
		return -1;
	m->type = d[0];
	memcpy(&m->txn, d + 1, 2);
	memcpy(&m->id, d + 3, 2);
	memcpy(&m->len, d + 5, 2);
	if (m->len > n - 7)
		m->len = (uint16_t)(n - 7);
	m->tlv = d + 7;
	return 0;
}

const uint8_t *qmi_get(const struct qmi_msg *m, uint8_t t, uint16_t *len)
{
	for (uint32_t o = 0; o + 3 <= m->len;) {
		uint16_t l;
		memcpy(&l, m->tlv + o + 1, 2);
		if (o + 3 + l > m->len)
			break;
		if (m->tlv[o] == t) {
			if (len)
				*len = l;
			return m->tlv + o + 3;
		}
		o += 3 + l;
	}
	return NULL;
}

int qmi_get_u32(const struct qmi_msg *m, uint8_t t, uint32_t *v)
{
	uint16_t l;
	const uint8_t *p = qmi_get(m, t, &l);
	if (!p || l < 4)
		return -1;
	memcpy(v, p, 4);
	return 0;
}

int qmi_get_u8(const struct qmi_msg *m, uint8_t t, uint8_t *v)
{
	uint16_t l;
	const uint8_t *p = qmi_get(m, t, &l);
	if (!p || l < 1)
		return -1;
	*v = p[0];
	return 0;
}

void qmi_dump(const struct qmi_msg *m)
{
	printf("qmi: type %u txn %u msg %#x len %u:", m->type, m->txn, m->id, m->len);
	for (uint32_t o = 0; o + 3 <= m->len;) {
		uint16_t l;
		memcpy(&l, m->tlv + o + 1, 2);
		printf(" [%#x/%u", m->tlv[o], l);
		for (uint16_t k = 0; k < l && k < 24 && o + 3 + k < m->len; k++)
			printf(" %02x", m->tlv[o + 3 + k]);
		printf("%s]", l > 24 ? " ..." : "");
		o += 3 + l;
	}
	printf("\n");
}
