/*
 * prefs: read/write CFPreferences through cfprefsd (no `defaults` on iOS).
 *   prefs DOMAIN KEY                        read      (DOMAIN "-g" = global)
 *   prefs DOMAIN KEY bool|int|string VALUE  write
 *   prefs DOMAIN KEY delete
 * Acts as the mobile user (501) when run as root, which is whose preferences apps read.
 */
#import <Foundation/Foundation.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 3) {
			fprintf(stderr, "usage: prefs DOMAIN KEY [bool|int|string VALUE | delete]\n");
			return 2;
		}
		if (getuid() == 0) {
			setgid(501);
			setuid(501);
		}
		CFStringRef dom = !strcmp(argv[1], "-g") ? kCFPreferencesAnyApplication
							   : (__bridge CFStringRef) @(argv[1]);
		CFStringRef key = (__bridge CFStringRef) @(argv[2]);
		if (argc >= 4) {
			id v = nil;
			if (!strcmp(argv[3], "delete"))
				v = nil;
			else if (argc >= 5 && !strcmp(argv[3], "bool"))
				v = @(!strcmp(argv[4], "1") || !strcasecmp(argv[4], "yes") || !strcasecmp(argv[4], "true"));
			else if (argc >= 5 && !strcmp(argv[3], "int"))
				v = @(atoll(argv[4]));
			else if (argc >= 5)
				v = @(argv[4]);
			CFPreferencesSetValue(key, (__bridge CFPropertyListRef)v, dom, kCFPreferencesCurrentUser,
					      kCFPreferencesAnyHost);
			CFPreferencesSynchronize(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		}
		id cur = CFBridgingRelease(CFPreferencesCopyValue(key, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
		printf("%s %s = %s\n", argv[1], argv[2], cur ? [[cur description] UTF8String] : "(unset)");
	}
	return 0;
}
