#ifndef WLFW_H
#define WLFW_H
#include "link.h"
#define WLFW_SERVICE	0x45
#define WLFW_PORT	0x20	/* our client port */
struct wlfw_info {
	uint32_t chip_id, chip_family, board_id, soc_id, fw_version;
	char build_id[130];
};
extern struct wlfw_info wlfw;
void wlfw_new_server(uint32_t node, uint32_t port);
int wlfw_pending(void);		/* the server is up, not started yet */
int wlfw_start(void);
void wlfw_handle(const struct qrtr_hdr *h, const uint8_t *d, uint32_t n);
#endif
