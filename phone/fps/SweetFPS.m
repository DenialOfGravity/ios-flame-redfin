/*
 * SweetFPS.dylib (ws-u-fps): what UI processes ask CADisplayLink for, and optionally a different answer.
 *
 * On redfin's 90 Hz heartbeat (backboardd CA_HEARTBEAT_RATE=90) UIKit's settle animations (scroll deceleration end,
 * page snap, springs; thread com.apple.UIKit.inProcessAnimationManager) run every 3rd tick (30 Hz) while app display
 * links run at 90 Hz. Presumably a 60 fps request (iPhone X: UIScreen.maximumFramesPerSecond 60) that CA quantises
 * onto 90/n. This library logs every rate request with its thread, and can rewrite the requests.
 *
 * Inserted with DYLD_INSERT_LIBRARIES=/var/local/lib/SweetFPS.dylib: xnu 0999 (boot sweetfbx |= 0x100) does it for
 * SpringBoard and apps with SWEET_FPS=2, or SpringBoard's launchd EnvironmentVariables. Mode: the file
 * /var/local/sweetfps ("MODE [TARGET]", read when readable, i.e. not inside app sandboxes), else the environment:
 *   SWEET_FPS=MODE    bit 0 log (NSLog "SweetFPS: ..."; bit 2 also appends to /var/tmp/sweetfps.log)
 *                     bit 1 rewrite: preferredFramesPerSecond / preferredFrameRateRange whose rate (max) is
 *                           in [MIN, TARGET) becomes TARGET (range: {min, TARGET, TARGET})
 *                     bit 3 rewrite to 0 / CAFrameRateRangeDefault instead of TARGET
 *   SWEET_FPS_TARGET=N (default 90), SWEET_FPS_MIN=N (default 25: requests below 25 fps are left alone); the mode
 *   file takes both: "MODE TARGET MIN". The rate tested is a range's maximum (its preferred when the maximum is 0):
 *   UIKit's inProcessAnimationManager asks for {20 30 0} (frame interval 3 on the 90 Hz heartbeat).
 * Hooks: -[CADisplayLink setPreferredFramesPerSecond:], setPreferredFrameRateRange:, setFrameInterval:,
 * addToRunLoop:forMode: (logs the link's rate state and the thread when it starts, and again 2 s later); each log
 * line carries the link's own view: heartbeatRate, maximumRefreshRate, minimumFrameDuration, frameInterval,
 * actualFramesPerSecond (private getters).
 */
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned sf_mode;
static float sf_target = 90, sf_min = 25;
static FILE *sf_file;

static void
sf_log(NSString *what)
{
	char th[64] = "";
	pthread_getname_np(pthread_self(), th, sizeof(th));
	const char *q = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
	NSString *line = [NSString stringWithFormat:@"SweetFPS: %s[%d] thread '%s' queue '%s'%s: %@", getprogname(), getpid(),
	    th, q ? q : "", pthread_main_np() ? " (main)" : "", what];
	NSLog(@"%@", line);
	if (sf_file != NULL) {
		fprintf(sf_file, "%s\n", line.UTF8String);
		fflush(sf_file);
	}
}

static NSString *
sf_caller(void)
{
	/* the two frames above the hook: UIKit / QuartzCore return addresses (a2s / imgdump imp resolve them) */
	NSArray<NSNumber *> *a = [NSThread callStackReturnAddresses];
	NSMutableString *s = [NSMutableString string];
	for (NSUInteger i = 2; i < a.count && i < 6; i++) {
		[s appendFormat:@" %#llx", a[i].unsignedLongLongValue];
	}
	return s;
}

/* the link's view of the display (private CADisplayLink getters, iOS 16 QuartzCore): heartbeat and refresh as rates,
 * minimum frame duration (in heartbeat ticks), frame interval, actual fps */
static NSString *
sf_state(id link)
{
	double hb = 0, mr = 0;
	long mfd = 0, fi = 0, afps = 0;
	SEL s;
	if ([link respondsToSelector:(s = sel_registerName("heartbeatRate"))]) {
		hb = ((double (*)(id, SEL))objc_msgSend)(link, s);
	}
	if ([link respondsToSelector:(s = sel_registerName("maximumRefreshRate"))]) {
		mr = ((double (*)(id, SEL))objc_msgSend)(link, s);
	}
	if ([link respondsToSelector:(s = sel_registerName("minimumFrameDuration"))]) {
		mfd = ((long (*)(id, SEL))objc_msgSend)(link, s);
	}
	if ([link respondsToSelector:(s = sel_registerName("frameInterval"))]) {
		fi = ((long (*)(id, SEL))objc_msgSend)(link, s);
	}
	if ([link respondsToSelector:(s = sel_registerName("actualFramesPerSecond"))]) {
		afps = ((long (*)(id, SEL))objc_msgSend)(link, s);
	}
	return [NSString stringWithFormat:@"[heartbeat %g (%.2f/s) maxRefresh %g (%.2f/s) minFrameDuration %ld frameInterval %ld actualFPS %ld]",
	    hb, hb > 0 ? 1 / hb : 0, mr, mr > 0 ? 1 / mr : 0, mfd, fi, afps];
}

static bool
sf_rewrites(float rate)
{
	return (sf_mode & 2) && rate >= sf_min && rate < sf_target;
}

static void
sf_hook(void)
{
	Class c = objc_getClass("CADisplayLink");
	if (c == Nil) {
		return;
	}
	SEL s1 = sel_registerName("setPreferredFramesPerSecond:");
	Method m1 = class_getInstanceMethod(c, s1);
	if (m1 != NULL) {
		__block void (*orig)(id, SEL, NSInteger) = NULL;
		IMP n = imp_implementationWithBlock(^(id self, NSInteger fps) {
			NSInteger v = fps;
			if (sf_rewrites((float)fps)) {
				v = (sf_mode & 8) ? 0 : (NSInteger)sf_target;
			}
			if (sf_mode & 1) {
				sf_log([NSString stringWithFormat:@"%p setPreferredFramesPerSecond:%ld%@ from%@", self, (long)fps,
				    v != fps ? [NSString stringWithFormat:@" -> %ld", (long)v] : @"", sf_caller()]);
			}
			orig(self, s1, v);
			if (sf_mode & 1) {
				sf_log([NSString stringWithFormat:@"%p after: %@", self, sf_state(self)]);
			}
		});
		orig = (void (*)(id, SEL, NSInteger))method_setImplementation(m1, n);
	}
	SEL s2 = sel_registerName("setPreferredFrameRateRange:");
	Method m2 = class_getInstanceMethod(c, s2);
	if (m2 != NULL) {
		__block void (*orig)(id, SEL, CAFrameRateRange) = NULL;
		IMP n = imp_implementationWithBlock(^(id self, CAFrameRateRange r) {
			CAFrameRateRange v = r;
			float top = r.maximum > 0 ? r.maximum : r.preferred;
			if (sf_rewrites(top)) {
				v = (sf_mode & 8) ? CAFrameRateRangeDefault : CAFrameRateRangeMake(r.minimum, sf_target, sf_target);
			}
			if (sf_mode & 1) {
				sf_log([NSString stringWithFormat:@"%p setPreferredFrameRateRange:{%g %g %g}%@ from%@", self,
				    r.minimum, r.maximum, r.preferred, CAFrameRateRangeIsEqualToRange(v, r) ? @"" :
				    [NSString stringWithFormat:@" -> {%g %g %g}", v.minimum, v.maximum, v.preferred], sf_caller()]);
			}
			orig(self, s2, v);
			if (sf_mode & 1) {
				sf_log([NSString stringWithFormat:@"%p after: %@", self, sf_state(self)]);
			}
		});
		orig = (void (*)(id, SEL, CAFrameRateRange))method_setImplementation(m2, n);
	}
	SEL s3 = sel_registerName("setFrameInterval:");
	Method m3 = class_getInstanceMethod(c, s3);
	if (m3 != NULL) {
		__block void (*orig)(id, SEL, NSInteger) = NULL;
		IMP n = imp_implementationWithBlock(^(id self, NSInteger k) {
			if (sf_mode & 1) {       /* logged only */
				sf_log([NSString stringWithFormat:@"%p setFrameInterval:%ld from%@", self, (long)k, sf_caller()]);
			}
			orig(self, s3, k);
		});
		orig = (void (*)(id, SEL, NSInteger))method_setImplementation(m3, n);
	}
	SEL s4 = sel_registerName("addToRunLoop:forMode:");
	Method m4 = class_getInstanceMethod(c, s4);
	if (m4 != NULL) {
		__block void (*orig)(id, SEL, NSRunLoop *, NSRunLoopMode) = NULL;
		IMP n = imp_implementationWithBlock(^(CADisplayLink *self, NSRunLoop *rl, NSRunLoopMode mode) {
			if (sf_mode & 1) {
				CAFrameRateRange r = self.preferredFrameRateRange;
				sf_log([NSString stringWithFormat:@"%p addToRunLoop mode %@ fps %ld range {%g %g %g} from%@",
				    self, mode, (long)self.preferredFramesPerSecond, r.minimum, r.maximum, r.preferred, sf_caller()]);
			}
			orig(self, s4, rl, mode);
			if (sf_mode & 1) {
				sf_log([NSString stringWithFormat:@"%p added: %@", self, sf_state(self)]);
				__weak CADisplayLink *weak = self;
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
					CADisplayLink *l = weak;
					if (l != nil) {
						sf_log([NSString stringWithFormat:@"%p 2 s later: paused %d %@", l, l.paused, sf_state(l)]);
					}
				});
			}
		});
		orig = (void (*)(id, SEL, NSRunLoop *, NSRunLoopMode))method_setImplementation(m4, n);
	}
}

__attribute__((constructor)) static void
sf_init(void)
{
	/* the file (readable outside app sandboxes) overrides the environment (SWEET_FPS=2 from xnu 0999) */
	const char *e = NULL;
	char buf[64] = "";
	FILE *f = fopen("/var/local/sweetfps", "r");
	if (f != NULL) {
		if (fgets(buf, sizeof(buf), f) != NULL) {
			e = buf;
		}
		fclose(f);
	}
	if (e == NULL) {
		e = getenv("SWEET_FPS");
	}
	unsetenv("DYLD_INSERT_LIBRARIES");      /* children must not inherit the insertion */
	if (e == NULL) {
		return;
	}
	char *end = NULL;
	sf_mode = (unsigned)strtoul(e, &end, 0);
	if (end != NULL && *end == ' ') {
		sf_target = (float)strtod(end + 1, &end);
		if (end != NULL && *end == ' ') {
			sf_min = (float)strtod(end + 1, NULL);  /* "MODE TARGET MIN" */
		}
	}
	if ((e = getenv("SWEET_FPS_TARGET")) != NULL) {
		sf_target = (float)atof(e);
	}
	if ((e = getenv("SWEET_FPS_MIN")) != NULL) {
		sf_min = (float)atof(e);
	}
	if (sf_mode == 0) {
		return;
	}
	if (sf_mode & 4) {
		sf_file = fopen("/var/tmp/sweetfps.log", "a");
	}
	sf_hook();
	if (sf_mode & 1) {
		sf_log([NSString stringWithFormat:@"on, mode %#x target %g min %g", sf_mode, sf_target, sf_min]);
	}
}
