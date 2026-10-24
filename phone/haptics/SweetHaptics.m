/*
 * SweetHaptics.dylib: UIKit haptic feedback and the system vibrate sound on redfin's
 * DRV2624 motor. The kernel (xnu 0912) inserts it into SpringBoard and apps when booted
 * with sweetui=1 and the file is at /var/local/lib/SweetHaptics.dylib; each pulse is one
 * sysctl write (kern.sweet_haptic = ms | strength << 16) that only queues it for the
 * driver's thread, so callers never wait on the motor.
 *
 * Covered: UIImpactFeedbackGenerator (impactOccurred, ...WithIntensity:),
 * UISelectionFeedbackGenerator (selectionChanged), UINotificationFeedbackGenerator
 * (notificationOccurred:), and AudioServicesPlaySystemSound/AlertSound (and the
 * WithCompletion forms) for kSystemSoundID_Vibrate (4095) and the peek/pop/nope haptics
 * (1519-1521). The original UIKit/AudioToolbox code still runs afterwards.
 *
 * SWEET_HAPTICS=0 in a process's environment turns it off there; SWEET_HAPTICS_LOG=1 logs
 * each pulse to the console (oslog).
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>

static int sh_ok;               /* 1: the sysctl exists */
static int sh_log;

static void
sh_pulse(unsigned ms, unsigned strength)
{
	if (!sh_ok) {
		return;
	}
	int v = (int)((ms & 0xffffu) | ((strength & 0xffu) << 16));
	(void)sysctlbyname("kern.sweet_haptic", NULL, NULL, &v, sizeof(v));
	if (sh_log) {
		NSLog(@"SweetHaptics: %u ms strength %u", ms, strength);
	}
}

/* Replace cls's instance method sel with block(self, args...) that runs pre() then the original. */
#define SH_HOOK0(cls, selname, ms, st) do {                                                     \
	SEL s_ = sel_registerName(selname);                                                     \
	Method m_ = class_getInstanceMethod(cls, s_);                                           \
	if (m_) {                                                                               \
		__block void (*orig_)(id, SEL) = NULL;                                          \
		IMP n_ = imp_implementationWithBlock(^(id self_) {                              \
			sh_pulse(ms, st);                                                       \
			orig_(self_, s_);                                                       \
		});                                                                             \
		orig_ = (void (*)(id, SEL))method_setImplementation(m_, n_);                    \
	}                                                                                       \
} while (0)

static void
sh_hook_uikit(void)
{
	Class impact = objc_getClass("UIImpactFeedbackGenerator");
	Class selection = objc_getClass("UISelectionFeedbackGenerator");
	Class notification = objc_getClass("UINotificationFeedbackGenerator");
	if (impact) {
		/* style: 0 light, 1 medium, 2 heavy, 3 soft, 4 rigid */
		SEL s = @selector(impactOccurred);
		Method m = class_getInstanceMethod(impact, s);
		if (m) {
			__block void (*orig)(id, SEL) = NULL;
			IMP n = imp_implementationWithBlock(^(id self) {
				NSInteger style = 1;
				@try {
					id v = [self valueForKey:@"_style"];
					if ([v respondsToSelector:@selector(integerValue)]) {
						style = [v integerValue];
					}
				} @catch (__unused id e) {
				}
				static const unsigned ms[5] = {12, 18, 26, 16, 10}, st[5] = {80, 110, 127, 70, 127};
				unsigned i = style >= 0 && style < 5 ? (unsigned)style : 1;
				sh_pulse(ms[i], st[i]);
				orig(self, s);
			});
			orig = (void (*)(id, SEL))method_setImplementation(m, n);
		}
		SEL si = @selector(impactOccurredWithIntensity:);
		Method mi = class_getInstanceMethod(impact, si);
		if (mi) {
			__block void (*origi)(id, SEL, CGFloat) = NULL;
			IMP n = imp_implementationWithBlock(^(id self, CGFloat intensity) {
				CGFloat k = intensity < 0 ? 0 : intensity > 1 ? 1 : intensity;
				sh_pulse(10 + (unsigned)(14 * k), 50 + (unsigned)(77 * k));
				origi(self, si, intensity);
			});
			origi = (void (*)(id, SEL, CGFloat))method_setImplementation(mi, n);
		}
	}
	if (selection) {
		SH_HOOK0(selection, "selectionChanged", 8, 70);
	}
	if (notification) {
		SEL s = @selector(notificationOccurred:);
		Method m = class_getInstanceMethod(notification, s);
		if (m) {
			__block void (*orig)(id, SEL, NSInteger) = NULL;
			IMP n = imp_implementationWithBlock(^(id self, NSInteger type) {
				/* 0 success, 1 warning, 2 error */
				sh_pulse(type == 2 ? 60 : type == 1 ? 45 : 30, 127);
				orig(self, s, type);
			});
			orig = (void (*)(id, SEL, NSInteger))method_setImplementation(m, n);
		}
	}
}

/* ---- AudioToolbox, by dyld interposing ---- */
static bool
sh_sound(SystemSoundID id)
{
	switch (id) {
	case kSystemSoundID_Vibrate:
		sh_pulse(400, 127);
		return true;
	case 1519:              /* peek */
		sh_pulse(12, 90);
		return true;
	case 1520:              /* pop */
		sh_pulse(22, 127);
		return true;
	case 1521:              /* nope */
		sh_pulse(40, 110);
		return true;
	}
	return false;
}

static void
sh_PlaySystemSound(SystemSoundID id)
{
	(void)sh_sound(id);
	AudioServicesPlaySystemSound(id);
}

static void
sh_PlayAlertSound(SystemSoundID id)
{
	(void)sh_sound(id);
	AudioServicesPlayAlertSound(id);
}

static void
sh_PlaySystemSoundWithCompletion(SystemSoundID id, void (^done)(void))
{
	(void)sh_sound(id);
	AudioServicesPlaySystemSoundWithCompletion(id, done);
}

static void
sh_PlayAlertSoundWithCompletion(SystemSoundID id, void (^done)(void))
{
	(void)sh_sound(id);
	AudioServicesPlayAlertSoundWithCompletion(id, done);
}

__attribute__((used)) static const struct {
	const void *replacement;
	const void *replacee;
} sh_interpose[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)sh_PlaySystemSound, (const void *)AudioServicesPlaySystemSound },
	{ (const void *)sh_PlayAlertSound, (const void *)AudioServicesPlayAlertSound },
	{ (const void *)sh_PlaySystemSoundWithCompletion, (const void *)AudioServicesPlaySystemSoundWithCompletion },
	{ (const void *)sh_PlayAlertSoundWithCompletion, (const void *)AudioServicesPlayAlertSoundWithCompletion },
};

__attribute__((constructor)) static void
sh_init(void)
{
	const char *e = getenv("SWEET_HAPTICS");
	if (e && strcmp(e, "0") == 0) {
		return;
	}
	e = getenv("SWEET_HAPTICS_LOG");
	sh_log = e && strcmp(e, "1") == 0;
	int v = 0;
	size_t len = sizeof(v);
	sh_ok = sysctlbyname("kern.sweet_haptic", &v, &len, NULL, 0) == 0;
	/* Children (and anything spawned later) must not inherit the insertion. */
	unsetenv("DYLD_INSERT_LIBRARIES");
	if (!sh_ok) {
		return;
	}
	sh_hook_uikit();
	if (sh_log) {
		NSLog(@"SweetHaptics: on in %s", getprogname());
	}
}
