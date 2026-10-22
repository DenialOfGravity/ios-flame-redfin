/*
 * runmigrator: run one DataMigration plugin by hand, as
 * com.apple.migrationpluginwrapper would, with its os_log output on stderr
 * (run with OS_ACTIVITY_DT_MODE=YES). Signed with the wrapper's entitlements
 * (installd only serves entitled clients).
 *
 *   runmigrator /System/Library/DataClassMigrators/SystemAppMigrator.migrator [disposition] [upgrade]
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

@interface DataClassMigrator : NSObject
+ (id)dataClassMigratorForBundleAtPath:(NSString *)path;
- (BOOL)performMigration;
- (void)setUserDataDisposition:(unsigned int)d;
- (void)setDidUpgrade:(BOOL)u;
- (void)setContext:(NSDictionary *)c;
@end

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2) {
			fprintf(stderr, "usage: runmigrator BUNDLE [disposition] [didUpgrade]\n");
			return 2;
		}
		if (!dlopen("/System/Library/PrivateFrameworks/DataMigration.framework/DataMigration", RTLD_NOW)) {
			fprintf(stderr, "dlopen DataMigration: %s\n", dlerror());
			return 1;
		}
		Class dcm = NSClassFromString(@"DataClassMigrator");
		id m = [dcm dataClassMigratorForBundleAtPath:[NSString stringWithUTF8String:argv[1]]];
		if (!m) {
			fprintf(stderr, "no migrator from %s\n", argv[1]);
			return 1;
		}
		[m setUserDataDisposition:argc > 2 ? (unsigned)atoi(argv[2]) : 0];
		[m setDidUpgrade:argc > 3 ? atoi(argv[3]) != 0 : NO];
		fprintf(stderr, "running %s\n", [[m description] UTF8String]);
		BOOL ok = [m performMigration];
		fprintf(stderr, "performMigration -> %d\n", ok);
		return ok ? 0 : 1;
	}
}
