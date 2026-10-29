/*
 * autolock [get | never | SECONDS]: Settings > Display & Brightness > Auto-Lock without the UI, through
 * ManagedConfiguration as Settings does (MCProfileConnection, setting "maxInactivity"; profiled stores it and
 * tells SpringBoard). never = INT_MAX (what Settings stores for Never); the iOS default is 60 (1 minute).
 * Benches: autolock never before, autolock 60 after (or keep never while the phone is on the desk).
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface MCProfileConnection : NSObject
+ (instancetype)sharedConnection;
- (id)effectiveValueForSetting:(NSString *)setting;
- (void)setValue:(id)value forSetting:(NSString *)setting;
@end

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (!dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY)) {
			fprintf(stderr, "ManagedConfiguration: %s\n", dlerror());
			return 1;
		}
		Class c = NSClassFromString(@"MCProfileConnection");
		MCProfileConnection *mc = [c sharedConnection];
		if (mc == nil) {
			fprintf(stderr, "no MCProfileConnection\n");
			return 1;
		}
		id before = [mc effectiveValueForSetting:@"maxInactivity"];
		if (argc > 1 && strcmp(argv[1], "get")) {
			long v = !strcmp(argv[1], "never") ? INT_MAX : strtol(argv[1], NULL, 10);
			if (v <= 0) {
				fprintf(stderr, "usage: autolock [get | never | SECONDS]\n");
				return 2;
			}
			[mc setValue:@(v) forSetting:@"maxInactivity"];
			[NSThread sleepForTimeInterval:0.5];
		}
		id now = [mc effectiveValueForSetting:@"maxInactivity"];
		printf("maxInactivity %s%s%s\n", [[before description] UTF8String], argc > 1 && strcmp(argv[1], "get") ? " -> " : "",
		    argc > 1 && strcmp(argv[1], "get") ? [[now description] UTF8String] : "");
	}
	return 0;
}
