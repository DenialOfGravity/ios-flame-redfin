#ifndef PDMAPPER_H
#define PDMAPPER_H
#include "link.h"
#define PDMAPPER_SERVICE	0x40
#define PDMAPPER_PORT		0x11
int pdmapper_init(void);
void pdmapper_handle(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n);
#endif
