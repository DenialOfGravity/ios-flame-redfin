/*
 * redfin (lito, SM7250): doorbells to the modem and the AOP go through the IPCC
 * mailbox, not the APCS IPC register sm8150/sm7150 use (write BIT(n) at 0x17c0000c).
 * Linux drivers/soc/qcom/qcom_ipcc.c: write (client_id << 16 | signal_id) to
 * IPCC_REG_SEND_ID. IDs: dt-bindings/soc/qcom,ipcc.h; mboxes in lito.dtsi.
 */
#ifndef IPCC_H
#define IPCC_H
#include <stdint.h>

#define IPCC_BASE		0x00408000ull	/* ipcc_mproc: qcom,ipcc@408000 */
#define IPCC_SEND_ID		(IPCC_BASE + 0x0c)
#define IPCC_ID(client, signal)	(((uint32_t)(client) << 16) | (uint32_t)(signal))
#define IPCC_CLIENT_AOP		0
#define IPCC_CLIENT_MPSS	2
#define IPCC_SIGNAL_GLINK_QMP	0
#define IPCC_SIGNAL_SMP2P	2

#define DB_MODEM_GLINK	IPCC_ID(IPCC_CLIENT_MPSS, IPCC_SIGNAL_GLINK_QMP)
#define DB_MODEM_SMP2P	IPCC_ID(IPCC_CLIENT_MPSS, IPCC_SIGNAL_SMP2P)
#define DB_AOSS		IPCC_ID(IPCC_CLIENT_AOP, IPCC_SIGNAL_GLINK_QMP)

#endif
