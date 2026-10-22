/* expt: ask ExtensionFoundation's extension point catalog (what installd uses) about points. */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

@interface EXExtensionPointCatalog : NSObject
- (id)extensionPointForIdentifier:(NSString *)i platform:(unsigned)p;
- (NSDictionary *)extensionPointByIdentifierPlatform;
@end

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (getenv("EXPT_UID")) {	/* query as another user, e.g. 33 = _installd */
			setgid(atoi(getenv("EXPT_UID")));
			setuid(atoi(getenv("EXPT_UID")));
		}
		dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
		id cat = [[NSClassFromString(@"EXExtensionPointCatalog") alloc] init];
		NSDictionary *all = [cat extensionPointByIdentifierPlatform];
		printf("catalog: %lu entries\n", (unsigned long)all.count);
		for (int i = 1; i < argc; i++) {
			printf("%s: platforms", argv[i]);
			for (unsigned pl = 0; pl < 16; pl++)
				if ([cat extensionPointForIdentifier:[NSString stringWithUTF8String:argv[i]] platform:pl])
					printf(" %u", pl);
			printf("\n");
		}
		void *icl = dlopen("/System/Library/PrivateFrameworks/InstalledContentLibrary.framework/InstalledContentLibrary", RTLD_NOW);
		id (*copyEntry)(NSString *, unsigned, NSError **) = icl ? dlsym(icl, "MICopyExtensionCacheEntryWithPlatform") : NULL;
		for (int i = 1; i < argc && copyEntry; i++) {
			NSError *err = nil;
			id e = copyEntry([NSString stringWithUTF8String:argv[i]], 2, &err);
			printf("MICopyExtensionCacheEntryWithPlatform(%s, 2): %s %s\n", argv[i], e ? "entry" : "nil",
			       err ? [[err description] UTF8String] : "");
		}
		int n = 0;
		for (id k in all) {
			if (n++ < 8)
				printf("  e.g. %s\n", [[k description] UTF8String]);
		}
	}
	return 0;
}
