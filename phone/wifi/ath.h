/* WCN3990 copy engines + HTC from userland, polled (Linux ath10k ce.c, snoc.c, htc.c). */
#ifndef ATH_H
#define ATH_H
#include <stdint.h>
#include <stddef.h>

#define HTC_SVC_RSVD_CTRL	0x0001
#define HTC_SVC_WMI_CONTROL	0x0100
#define HTC_SVC_HTT_DATA	0x0300

/* Called for each received HTC message on a connected endpoint (not EP0). */
typedef void (*htc_rx_cb_t)(int eid, const uint8_t *data, uint32_t len);

int ath_ce_init(void);			/* rings, RRI, rx buffers; after WLFW mission mode */
int ath_htc_start(htc_rx_cb_t cb);	/* READY, connect HTT + WMI, setup complete */
int ath_htc_send(int eid, const void *data, uint32_t len);	/* waits for credits on the WMI endpoint */
void ath_poll(void);			/* drain every receive ring */
extern int ath_wmi_eid, ath_htt_eid;

#endif
