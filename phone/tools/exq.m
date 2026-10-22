/* exq: run an ExtensionFoundation query (what PosterBoard's provider does) and list the extensions it finds. */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

@interface _EXQuery : NSObject
- (id)initWithExtensionPointIdentifier:(NSString *)identifier;
@end
@interface _EXQueryController : NSObject
+ (NSArray *)executeQuery:(id)query;
+ (void)executeQuery:(id)query completionHandler:(void (^)(NSArray *))handler;
@end

int main(int argc, char **argv)
{
	@autoreleasepool {
		dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
		dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
		/* what LaunchServices itself holds: app records vs extension records */
		unsigned long apps = 0, exts = 0;
		for (id r in [NSClassFromString(@"LSApplicationRecord") performSelector:@selector(enumeratorWithOptions:) withObject:nil])
			apps++, (void)r;
		NSCountedSet *points = [NSCountedSet set];
		for (id r in [NSClassFromString(@"LSApplicationExtensionRecord") performSelector:@selector(enumeratorWithOptions:) withObject:nil]) {
			exts++;
			id ep = [r performSelector:@selector(extensionPointRecord)];
			NSString *pid = [ep performSelector:@selector(identifier)] ?: @"(none)";
			[points addObject:pid];
			if (getenv("EXQ_LIST") && [pid isEqualToString:@(getenv("EXQ_LIST"))])
				printf("  %s %s\n", [[r performSelector:@selector(bundleIdentifier)] UTF8String],
				       [[[r performSelector:@selector(URL)] path] UTF8String]);
		}
		if (getenv("EXQ_POINTS"))
			for (NSString *pid in points)
				printf("  %3lu %s\n", (unsigned long)[points countForObject:pid], pid.UTF8String);
		printf("LaunchServices: %lu app records, %lu extension records\n", apps, exts);
		NSString *point = argc > 1 ? @(argv[1]) : @"com.apple.posterkit.provider";
		id q = [[NSClassFromString(@"_EXQuery") alloc] initWithExtensionPointIdentifier:point];
		NSDate *t0 = [NSDate date];
		NSArray *r = [NSClassFromString(@"_EXQueryController") executeQuery:q];
		printf("sync %s: %lu extensions (%.0f ms)\n", point.UTF8String, (unsigned long)r.count,
		       -[t0 timeIntervalSinceNow] * 1000);
		for (id e in r)
			printf("  %s\n", [[e description] UTF8String]);
		__block BOOL done = NO;
		t0 = [NSDate date];
		[NSClassFromString(@"_EXQueryController") executeQuery:q completionHandler:^(NSArray *a) {
			printf("async: %lu extensions (%.0f ms)\n", (unsigned long)a.count, -[t0 timeIntervalSinceNow] * 1000);
			done = YES;
		}];
		for (int i = 0; i < 100 && !done; i++)
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
		if (!done)
			printf("async: no answer in 10 s\n");
	}
	return 0;
}
