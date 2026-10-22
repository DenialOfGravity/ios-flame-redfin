#ifndef IPNET_H
#define IPNET_H
int ipnet_init(void);	/* a utun for the WLAN's IPv4; hooks into the radio (link up -> DHCP) */
void ipnet_poll(void);	/* from the link's idle loop */
#endif
