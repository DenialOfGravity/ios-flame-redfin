/*
 * openapp: launch an app by bundle id through FrontBoard (no icon tap needed).
 *   openapp BUNDLE_ID [URL]
 * FBSOpenApplicationService first (iOS 14+), FBSSystemService as the fallback; both ask SpringBoard
 * and need com.apple.frontboard.launchapplications (openapp-ents.plist).
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>

@interface FBSOpenApplicationOptions : NSObject
+ (instancetype)optionsWithDictionary:(NSDictionary *)dict;
@end

@interface FBSOpenApplicationService : NSObject
+ (instancetype)serviceWithDefaultShellEndpoint;
- (void)openApplication:(NSString *)bundleID withOptions:(FBSOpenApplicationOptions *)options
	     completion:(void (^)(id process, NSError *error))completion;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)openApplication:(NSString *)bundleID options:(NSDictionary *)options
	     withResult:(void (^)(NSError *error))result;
@end

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2) {
			fprintf(stderr, "usage: openapp BUNDLE_ID [URL]\n");
			return 2;
		}
		dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
		NSString *bid = [NSString stringWithUTF8String:argv[1]];
		NSMutableDictionary *opts = [@{ @"__UnlockDevice": @YES, @"__ActivateSuspended": @NO } mutableCopy];
		if (argc > 2)
			opts[@"__PayloadURL"] = [NSURL URLWithString:[NSString stringWithUTF8String:argv[2]]];
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block int rc = 1;

		Class svc = NSClassFromString(@"FBSOpenApplicationService");
		Class optc = NSClassFromString(@"FBSOpenApplicationOptions");
		if (svc && optc && [svc respondsToSelector:@selector(serviceWithDefaultShellEndpoint)]) {
			[[svc serviceWithDefaultShellEndpoint] openApplication:bid
				withOptions:[optc optionsWithDictionary:opts]
				completion:^(id process, NSError *error) {
					if (error)
						printf("open %s: %s\n", argv[1], error.description.UTF8String);
					else
						printf("open %s: %s\n", argv[1], [[process description] UTF8String]);
					rc = error != nil;
					dispatch_semaphore_signal(done);
				}];
		} else {
			[[NSClassFromString(@"FBSSystemService") sharedService] openApplication:bid options:opts
				withResult:^(NSError *error) {
					printf("open %s (FBSSystemService): %s\n", argv[1],
					       error ? error.description.UTF8String : "ok");
					rc = error != nil;
					dispatch_semaphore_signal(done);
				}];
		}
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC))) {
			printf("open %s: no answer in 30 s\n", argv[1]);
			return 1;
		}
		return rc;
	}
}
