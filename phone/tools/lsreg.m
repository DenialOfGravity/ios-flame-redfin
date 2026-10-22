/*
 * lsreg: LaunchServices registration on the phone (no uicache on iOS).
 *   lsreg APP_PATH...        register apps (e.g. /Applications/Calculator.app)
 *   lsreg -u APP_PATH...     unregister
 *   lsreg -r                 rebuild the app databases (system + internal + user)
 *   lsreg -l                 list installed apps: bundle id, type, path
 *   lsreg -p APPEX...        register plugins (.appex) by themselves
 * Signed with com.apple.migrationpluginwrapper's entitlements.
 */
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <objc/runtime.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)registerApplication:(NSURL *)url;
- (BOOL)unregisterApplication:(NSURL *)url;
- (BOOL)registerPlugin:(NSURL *)url;
- (BOOL)_LSPrivateRebuildApplicationDatabasesForSystemApps:(BOOL)s internal:(BOOL)i user:(BOOL)u;
- (NSArray *)allInstalledApplications;
@end

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)applicationType;
- (NSURL *)bundleURL;
- (BOOL)isPlaceholder;
@end

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (getenv("LSREG_UID")) {	/* e.g. 501 = mobile, whose database SpringBoard uses */
			setgid(atoi(getenv("LSREG_UID")));
			setuid(atoi(getenv("LSREG_UID")));
		}
		LSApplicationWorkspace *ws = [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
		if (argc < 2) {
			fprintf(stderr, "usage: lsreg [-u] APP... | -r | -l\n");
			return 2;
		}
		if (!strcmp(argv[1], "-r")) {
			BOOL ok = [ws _LSPrivateRebuildApplicationDatabasesForSystemApps:YES internal:YES user:YES];
			printf("rebuild -> %d\n", ok);
			return !ok;
		}
		if (!strcmp(argv[1], "-l")) {
			for (LSApplicationProxy *p in [ws allInstalledApplications])
				printf("%-45s %-8s %s%s\n", p.applicationIdentifier.UTF8String, p.applicationType.UTF8String,
				       p.bundleURL.path.UTF8String, p.isPlaceholder ? " (placeholder)" : "");
			return 0;
		}
		if (!strcmp(argv[1], "-p")) {
			int bad = 0;
			for (int i = 2; i < argc; i++) {
				/* what -registerPlugin: does, keeping the status it throws away */
				NSURL *u = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[i]]];
				/* not exported: -registerPlugin: calls it with bl at +0x28, target = start + 0x334 (20H392) */
				IMP imp = [ws methodForSelector:@selector(registerPlugin:)];
				printf("registerPlugin: at %p\n", (void *)imp);
				if (!imp)
					return 1;
				uint32_t bl = *(uint32_t *)((char *)imp + 0x28);
				int (*reg)(NSURL *, NSDictionary *) = (bl >> 26) == 0x25 ?
					(void *)((char *)imp + 0x28 + ((int32_t)(bl << 6) >> 4)) : NULL;
				int st = reg ? reg(u, nil) : -1;
				printf("register plugin %s -> %d\n", argv[i], st);
				bad += st != 0;
			}
			return bad != 0;
		}
		BOOL un = !strcmp(argv[1], "-u");
		int bad = 0;
		for (int i = un ? 2 : 1; i < argc; i++) {
			NSURL *u = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[i]]];
			BOOL ok = un ? [ws unregisterApplication:u] : [ws registerApplication:u];
			printf("%s %s -> %d\n", un ? "unregister" : "register", argv[i], ok);
			bad += !ok;
		}
		return bad != 0;
	}
}
