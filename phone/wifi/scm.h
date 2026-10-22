#ifndef SCM_H
#define SCM_H
#include <stdint.h>
#define VMID_HLOS	0x3
#define VMID_MSS_MSA	0xf
#define VMID_WLAN	0x18
#define VMID_WLAN_CE	0x19
/* Hand [pa, pa+size) from the src VMs to the dst VMs, each read/write. 0 = ok. */
int hyp_assign(uint64_t pa, uint64_t size, const uint32_t *src, int nsrc, const uint32_t *dst, int ndst);
#endif
