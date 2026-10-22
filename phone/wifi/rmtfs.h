#ifndef RMTFS_H
#define RMTFS_H
#include "link.h"
#define RMTFS_SERVICE	14
#define RMTFS_PORT	0x10
int rmtfs_init(void);
void rmtfs_handle(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n);
#endif
