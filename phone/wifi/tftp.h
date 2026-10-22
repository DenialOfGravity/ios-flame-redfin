#ifndef TFTP_H
#define TFTP_H
#include "link.h"
#define TFTP_SERVICE	4096
#define TFTP_PORT	0x12
#define TFTP_XFER_PORT0	0x100
#define TFTP_XFERS	8
#define TFTP_MAX_BLKSIZE 1024
int tftp_init(void);
void tftp_handle(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n);
#endif
