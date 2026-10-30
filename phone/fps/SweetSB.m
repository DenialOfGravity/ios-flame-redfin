/*
 * SweetSB (ws-z-ui): the status-bar clock clear of redfin's selfie-camera hole. Compiled into SweetFPS.dylib, which
 * xnu 0999 inserts into SpringBoard and every app when boot-arg sweetfbx has 0x100 (rk3a: 0x107), so no kernel change.
 *
 * The hole (LineageOS redfin cutout: centre 81,77 r 39 panel px) is CA x 44-125, y 40-121 = 14.6-41.7 pt across,
 * 13-40 pt down, inside the iPhone X status bar (44 pt) and its left "ear" (0-83 pt, Split58), where UIKit centres
 * the time at about 46 pt: "1:52" spans 32-61 pt and sits half under the hole. Moving the time right by ~18 pt
 * (centre 64 pt) clears it even for "12:59" (40 pt wide); the notch area to its right is empty glass on the Pixel.
 *
 * Switch: a flag file whose SIZE is 100 + DX (pt; DX may be negative). Only stat() is used: app sandboxes allow
 * file-read-metadata but not reads of /var/local. Read once at load: restart SpringBoard / relaunch apps after a change.
 *   /var/local/sweetsb.m   DX added to the split visual providers' +leadingCenteringOffset (the leading region's
 *                          centring: time and its pill/breadcrumb move together; read when a status bar is built)
 *   /var/local/sweetsb.t   fallback: the time views of _UIStatusBarTimeItem (shortTimeView, timeView, pillTimeView)
 *                          get a translation of DX pt on top of UIKit's own transform
 * No file: nothing hooked. Both: both apply. Make one: head -c 118 /dev/zero > /var/local/sweetsb.m  (DX +18).
 * SpringBoard (not sandboxed) appends what it hooked to /var/tmp/sweetsb.log.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>

static CGFloat sb_dxm, sb_dxt;
static char sb_assoc;

static bool
sb_flag(const char *path, CGFloat *dx)
{
	struct stat st;
	if (stat(path, &st) != 0 || st.st_size < 40 || st.st_size > 160) {
		return false;
	}
	*dx = (CGFloat)((long)st.st_size - 100);
	return true;
}

static void
sb_note(NSString *what)
{
	NSLog(@"SweetSB: %s[%d] %@", getprogname(), getpid(), what);
	if (strcmp(getprogname(), "SpringBoard") == 0) {
		FILE *f = fopen("/var/tmp/sweetsb.log", "a");
		if (f != NULL) {
			fprintf(f, "%s[%d] %s\n", getprogname(), getpid(), what.UTF8String);
			fclose(f);
		}
	}
}

/* +leadingCenteringOffset of each split provider that implements it itself (each Method hooked once). */
static int
sb_hook_centering(void)
{
	static const char *names[] = { "_UIStatusBarVisualProvider_Split58", "_UIStatusBarVisualProvider_Split54",
		"_UIStatusBarVisualProvider_Split61", "_UIStatusBarVisualProvider_Split65", "_UIStatusBarVisualProvider_Split",
		"_UIStatusBarVisualProvider_Split5_8", NULL };
	SEL sel = sel_registerName("leadingCenteringOffset");
	Method done[8];
	int n = 0;
	for (int i = 0; names[i] != NULL && n < 8; i++) {
		Class c = objc_getClass(names[i]);
		Method m = c != Nil ? class_getClassMethod(c, sel) : NULL;
		if (m == NULL) {
			continue;
		}
		bool seen = false;
		for (int k = 0; k < n; k++) {
			seen |= done[k] == m;
		}
		if (seen) {
			continue;
		}
		done[n++] = m;
		__block double (*orig)(id, SEL) = NULL;
		const CGFloat dx = sb_dxm;
		IMP imp = imp_implementationWithBlock(^double(id cls) {
			return orig(cls, sel) + dx;
		});
		orig = (double (*)(id, SEL))method_setImplementation(m, imp);
		sb_note([NSString stringWithFormat:@"+[%s leadingCenteringOffset] was %g, now +%g", names[i], orig(c, sel), dx]);
	}
	return n;
}

static void
sb_shift(UIView *v)
{
	if (v == nil) {
		return;
	}
	CGAffineTransform t = v.transform;
	NSNumber *mine = objc_getAssociatedObject(v, &sb_assoc);
	if (mine != nil && t.tx == mine.doubleValue) {
		return;         /* our shift is still there */
	}
	t.tx += sb_dxt;         /* in the superview: after UIKit's own transform (no CoreGraphics call) */
	v.transform = t;
	objc_setAssociatedObject(v, &sb_assoc, @(t.tx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static int
sb_hook_time_views(void)
{
	Class c = objc_getClass("_UIStatusBarTimeItem");
	if (c == Nil) {
		return 0;
	}
	static const char *getters[] = { "shortTimeView", "timeView", "pillTimeView", NULL };
	int n = 0;
	for (int i = 0; getters[i] != NULL; i++) {
		SEL sel = sel_registerName(getters[i]);
		Method m = class_getInstanceMethod(c, sel);
		if (m == NULL) {
			continue;
		}
		__block id (*orig)(id, SEL) = NULL;
		IMP imp = imp_implementationWithBlock(^id(id self) {
			id v = orig(self, sel);
			if ([v isKindOfClass:[UIView class]]) {
				sb_shift(v);
			}
			return v;
		});
		orig = (id (*)(id, SEL))method_setImplementation(m, imp);
		n++;
	}
	sb_note([NSString stringWithFormat:@"_UIStatusBarTimeItem: %d time-view getters shifted %g pt", n, sb_dxt]);
	return n;
}

__attribute__((constructor)) static void
sb_init(void)
{
	bool m = sb_flag("/var/local/sweetsb.m", &sb_dxm), t = sb_flag("/var/local/sweetsb.t", &sb_dxt);
	if (!m && !t) {
		return;
	}
	if (objc_getClass("UIStatusBar_Modern") == Nil && objc_getClass("_UIStatusBar") == Nil) {
		return;         /* no UIKit status bar in this process */
	}
	if (m && sb_hook_centering() == 0) {
		sb_note(@"no +leadingCenteringOffset found: use /var/local/sweetsb.t");
	}
	if (t) {
		sb_hook_time_views();
	}
}
