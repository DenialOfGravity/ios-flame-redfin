#ifndef BRIDGE_H
#define BRIDGE_H
int bridge_open(void);		/* /dev/wlan (kernel en0 + wifid): 0, or -1 (then wland keeps its own utun) */
void bridge_poll(void);		/* from the idle loop */
int bridge_active(void);
extern int bridge_joins;	/* wifid has asked for a network: wland's wlan.conf join stands down */
#endif
