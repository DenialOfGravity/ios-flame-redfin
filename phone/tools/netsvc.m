/*
 * netsvc: make a configured interface a network service iOS uses: publishes it in configd's dynamic
 * store, as IPConfiguration would for a configured interface, so IPMonitor makes it primary (default
 * route), mDNSResponder gets DNS servers and reachability says yes. Default: the USB link (ue0,
 * 192.168.7.2 via the Mac, which NATs for it: tools/mac-share.sh); wland publishes the WLAN's utun.
 *   netsvc [up]                               publish ue0 (again)
 *   netsvc up IF ADDR MASK ROUTER DNS [DNS2]  publish IF (one service per interface name)
 *   netsvc down [IF]                          remove        netsvc show [IF]     dump the keys
 * Signed with netsvc-ents.plist (SCDynamicStore write access).
 */
#import <Foundation/Foundation.h>
/* SystemConfiguration.framework has these on iOS; the SDK only marks them unavailable */
typedef const struct __SCDynamicStore *SCDynamicStoreRef;
extern SCDynamicStoreRef SCDynamicStoreCreate(CFAllocatorRef, CFStringRef, void *, void *);
extern CFPropertyListRef SCDynamicStoreCopyValue(SCDynamicStoreRef, CFStringRef);
extern Boolean SCDynamicStoreSetMultiple(SCDynamicStoreRef, CFDictionaryRef, CFArrayRef, CFArrayRef);
extern Boolean SCDynamicStoreRemoveValue(SCDynamicStoreRef, CFStringRef);
extern int SCError(void);
extern const char *SCErrorString(int);

/* ue0 keeps its old service ID; other interfaces get one derived from the name */
static NSString *service_id(NSString *ifname)
{
	if ([ifname isEqualToString:@"ue0"])
		return @"5EE7C0DE-0000-4000-8000-000000000001";
	uint32_t h = 2166136261u;
	for (const char *c = ifname.UTF8String; *c; c++)
		h = (h ^ (uint8_t)*c) * 16777619u;
	return [NSString stringWithFormat:@"5EE7C0DE-0000-4000-8000-0000%08X", h];
}

static void show(SCDynamicStoreRef st, NSString *ifname)
{
	NSString *svc = service_id(ifname);
	for (NSString *k in @[ @"State:/Network/Global/IPv4", @"State:/Network/Global/DNS",
			       [NSString stringWithFormat:@"State:/Network/Service/%@/IPv4", svc],
			       [NSString stringWithFormat:@"State:/Network/Service/%@/DNS", svc],
			       [NSString stringWithFormat:@"State:/Network/Interface/%@/IPv4", ifname] ]) {
		id v = CFBridgingRelease(SCDynamicStoreCopyValue(st, (__bridge CFStringRef)k));
		printf("%s = %s\n", k.UTF8String, v ? [[v description] UTF8String] : "(none)");
	}
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *cmd = argc > 1 ? argv[1] : "up";
		NSString *ifname = argc > 2 ? @(argv[2]) : @"ue0";
		NSString *addr = @"192.168.7.2", *mask = @"255.255.255.0", *router = @"192.168.7.1";
		NSArray *servers = @[ @"1.1.1.1", @"8.8.8.8" ];
		if (!strcmp(cmd, "up") && argc > 2) {
			if (argc < 7) {
				fprintf(stderr, "usage: netsvc up IF ADDR MASK ROUTER DNS [DNS2]\n");
				return 2;
			}
			addr = @(argv[3]);
			mask = @(argv[4]);
			router = @(argv[5]);
			servers = argc > 7 ? @[ @(argv[6]), @(argv[7]) ] : @[ @(argv[6]) ];
		}
		SCDynamicStoreRef st = SCDynamicStoreCreate(NULL, CFSTR("netsvc"), NULL, NULL);
		if (!st) {
			printf("netsvc: no dynamic store: %s\n", SCErrorString(SCError()));
			return 1;
		}
		NSString *svc = service_id(ifname);
		NSString *k4 = [NSString stringWithFormat:@"State:/Network/Service/%@/IPv4", svc];
		NSString *kd = [NSString stringWithFormat:@"State:/Network/Service/%@/DNS", svc];
		NSString *ki = [NSString stringWithFormat:@"State:/Network/Interface/%@/IPv4", ifname];
		if (!strcmp(cmd, "show")) {
			show(st, ifname);
			return 0;
		}
		if (!strcmp(cmd, "down")) {
			SCDynamicStoreRemoveValue(st, (__bridge CFStringRef)k4);
			SCDynamicStoreRemoveValue(st, (__bridge CFStringRef)kd);
			SCDynamicStoreRemoveValue(st, (__bridge CFStringRef)ki);
			printf("netsvc: %s removed\n", ifname.UTF8String);
			return 0;
		}
		NSDictionary *ipv4 = @{
			@"Addresses" : @[ addr ],
			@"SubnetMasks" : @[ mask ],
			@"Router" : router,
			@"InterfaceName" : ifname,
			@"ConfigMethod" : @"Manual",
		};
		NSDictionary *dns = @{ @"ServerAddresses" : servers };
		BOOL ok = SCDynamicStoreSetMultiple(st, (__bridge CFDictionaryRef)@{
			k4 : ipv4, kd : dns,
			ki : @{ @"Addresses" : @[ addr ], @"SubnetMasks" : @[ mask ] },
		}, NULL, NULL);
		printf("netsvc: publish %s -> %s\n", ifname.UTF8String, ok ? "ok" : SCErrorString(SCError()));
		sleep(1);	/* let IPMonitor recompute the primary service */
		show(st, ifname);
		return ok ? 0 : 1;
	}
}
