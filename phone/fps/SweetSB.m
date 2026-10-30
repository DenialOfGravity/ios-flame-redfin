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
 * ws-z-ui2 (v1 result: Split58 is absent on this UIKitCore, .m hooks nothing; .t's view transforms are overwritten,
 * because the display item owns its view's transform and the leading region positions it with constraints):
 *   /var/local/sweetsb.d   diagnostic (any size; one shot: SpringBoard deletes it at load): it logs the _UIStatusBar hierarchy (regions, their
 *                          properties, display items, view tree with window frames) to /var/tmp/sweetsb.log
 *   /var/local/sweetsb.x   DX pt: after every -[_UIStatusBar layoutSubviews], a translation of DX on the leading
 *                          region (identifier "leading"). How, from the size of /var/local/sweetsb.xm (100 + mode,
 *                          default 1): 1 = the region's contentView transform, 2 = each display item view's centre
 *                          moved by DX after layout, 3 = the region's layoutItem transform if it is a view.
 * No file: nothing hooked. Both: both apply. Make one: head -c 118 /dev/zero > /var/local/sweetsb.m  (DX +18).
 * SpringBoard (not sandboxed) appends what it hooked to /var/tmp/sweetsb.log.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <unistd.h>

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

/* ---- ws-z-ui2: diagnostic (.d) and the post-layout leading-region shift (.x) ---- */
static bool sb_diag;
static CGFloat sb_dxx;
static int sb_xmode = 1;
static int sb_dumps;
static char sb_dumped, sb_xassoc;

static id
sb_get(id o, NSString *key)
{
	if (o == nil || ![o respondsToSelector:NSSelectorFromString(key)]) {
		return nil;
	}
	@try {
		return [o valueForKey:key];
	} @catch (id e) {
		return nil;
	}
}

static NSString *
sb_r(CGRect r)
{
	return [NSString stringWithFormat:@"(%.1f,%.1f %.1fx%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *
sb_desc(id v)
{
	if (v == nil) {
		return @"nil";
	}
	if ([v isKindOfClass:[UIView class]]) {
		UIView *w = v;
		return [NSString stringWithFormat:@"%s%s win%@ tx %.1f a %.2f %@", class_getName([w class]), w.hidden ? " HIDDEN" : "",
			sb_r([w convertRect:w.bounds toView:nil]), w.transform.tx, w.alpha,
			w.translatesAutoresizingMaskIntoConstraints ? @"autoresize" : @"constraints"];
	}
	if ([v isKindOfClass:[UILayoutGuide class]]) {
		UILayoutGuide *g = v;
		CGRect r = g.owningView != nil ? [g.owningView convertRect:g.layoutFrame toView:nil] : g.layoutFrame;
		return [NSString stringWithFormat:@"%s '%@' win%@ owner %s", class_getName([g class]), g.identifier, sb_r(r),
			class_getName([g.owningView class])];
	}
	if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSValue class]]) {
		NSString *d = [v description];
		return d.length > 80 ? [d substringToIndex:80] : d;
	}
	if ([v respondsToSelector:@selector(count)]) {
		return [NSString stringWithFormat:@"%s count %lu", class_getName([v class]), (unsigned long)[v count]];
	}
	return [NSString stringWithFormat:@"%s", class_getName([v class])];
}

/* every object-valued property of o's class chain below NSObject/UIView/UIResponder */
static void
sb_props(id o, NSString *pre, NSMutableString *out)
{
	for (Class c = [o class]; c != Nil && c != [NSObject class] && c != [UIView class] && c != [UIResponder class];
		c = class_getSuperclass(c)) {
		unsigned n = 0;
		objc_property_t *pl = class_copyPropertyList(c, &n);
		for (unsigned i = 0; i < n; i++) {
			const char *nm = property_getName(pl[i]), *at = property_getAttributes(pl[i]);
			NSString *key = @(nm);
			if (at == NULL || at[1] != '@' || [key isEqualToString:@"description"] || [key isEqualToString:@"debugDescription"]) {
				[out appendFormat:@"%@  %s.%s [%s]\n", pre, class_getName(c), nm, at != NULL ? at + 1 : "?"];
				continue;
			}
			[out appendFormat:@"%@  %s.%s = %@\n", pre, class_getName(c), nm, sb_desc(sb_get(o, key))];
		}
		free(pl);
	}
}

static void
sb_tree(UIView *v, int depth, NSMutableString *out, int *lines)
{
	if (v == nil || depth > 7 || *lines > 120) {
		return;
	}
	(*lines)++;
	[out appendFormat:@"%*s%@\n", depth * 2, "", sb_desc(v)];
	for (UIView *s in v.subviews) {
		sb_tree(s, depth + 1, out, lines);
	}
}

static void
sb_dump(UIView *bar)
{
	NSMutableString *out = [NSMutableString string];
	[out appendFormat:@"==== DUMP %d %@ window %s scale %.3f\n", sb_dumps, sb_desc(bar), class_getName([bar.window class]),
		bar.window.screen.scale];
	@try {
		sb_props(bar, @"bar", out);
		id regions = sb_get(bar, @"regions");
		if ([regions isKindOfClass:[NSDictionary class]]) {
			for (id key in regions) {
				id rg = regions[key];
				[out appendFormat:@"-- region '%@' %s\n", key, class_getName([rg class])];
				sb_props(rg, @"rg", out);
				id items = sb_get(rg, @"displayItems");
				if ([items isKindOfClass:[NSDictionary class]]) {
					items = [items allValues];
				}
				int k = 0;
				for (id it in items) {
					[out appendFormat:@"   item %@ %s view %@\n", sb_get(it, @"identifier"), class_getName([it class]),
						sb_desc(sb_get(it, @"view"))];
					if (k++ == 0 && [key isEqual:@"leading"]) {
						sb_props(it, @"   it", out);
					}
				}
			}
		}
		[out appendString:@"-- view tree\n"];
		int lines = 0;
		sb_tree(bar, 0, out, &lines);
	} @catch (id e) {
		[out appendFormat:@"EXCEPTION %@\n", e];
	}
	sb_note(out);
}

static void
sb_xshift(UIView *bar)
{
	NSDictionary *regions = sb_get(bar, @"regions");
	if (![regions isKindOfClass:[NSDictionary class]]) {
		return;
	}
	id rg = regions[@"leading"];
	if (rg == nil) {
		return;
	}
	static int noted;
	NSMutableString *what = noted < 3 ? [NSMutableString string] : nil;
	if (sb_xmode == 1 || sb_xmode == 3) {
		UIView *v = sb_get(rg, sb_xmode == 1 ? @"contentView" : @"layoutItem");
		if ([v isKindOfClass:[UIView class]] && v != bar) {
			CGAffineTransform t = v.transform;
			if (t.tx != sb_dxx) {
				t.tx = sb_dxx;
				v.transform = t;
			}
			[what appendFormat:@"mode %d: %@", sb_xmode, sb_desc(v)];
		} else {
			[what appendFormat:@"mode %d: no view (%@)", sb_xmode, sb_desc(v)];
		}
	} else if (sb_xmode == 2) {
		id items = sb_get(rg, @"displayItems");
		if ([items isKindOfClass:[NSDictionary class]]) {
			items = [items allValues];
		}
		for (id it in items) {
			UIView *v = sb_get(it, @"view");
			if (![v isKindOfClass:[UIView class]] || v.superview == nil) {
				continue;
			}
			NSNumber *mine = objc_getAssociatedObject(v, &sb_xassoc);
			CGPoint c = v.center;
			if (mine == nil || fabs(c.x - mine.doubleValue) > 0.01) {
				c.x += sb_dxx;  /* fresh layout position: move it and remember where we put it */
				v.center = c;
				objc_setAssociatedObject(v, &sb_xassoc, @(c.x), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			}
			[what appendFormat:@"mode 2: %@ %@; ", sb_get(it, @"identifier"), sb_desc(v)];
		}
	}
	if (what != nil && bar.window != nil) {
		noted++;
		sb_note([NSString stringWithFormat:@"x shift %g: %@", sb_dxx, what]);
	}
}

static void
sb_after_layout(UIView *bar)
{
	if (sb_dxx != 0) {
		sb_xshift(bar);
	}
	if (sb_diag && sb_dumps < 6 && objc_getAssociatedObject(bar, &sb_dumped) == nil && bar.window != nil
		&& bar.bounds.size.width > 0) {
		objc_setAssociatedObject(bar, &sb_dumped, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		sb_dumps++;
		__weak UIView *wb = bar;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			UIView *b = wb;
			if (b != nil) {
				sb_dump(b);
			}
		});
	}
}

static void
sb_hook_layout(void)
{
	Class c = objc_getClass("_UIStatusBar");
	SEL sel = @selector(layoutSubviews);
	Method m = c != Nil ? class_getInstanceMethod(c, sel) : NULL;
	if (m == NULL) {
		sb_note(@"no -[_UIStatusBar layoutSubviews]");
		return;
	}
	void (*old)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
	IMP imp = imp_implementationWithBlock(^(UIView *self) {
		old(self, sel);
		sb_after_layout(self);
	});
	/* add on _UIStatusBar itself when it only inherits UIView's (never hook UIView for every view) */
	bool added = class_addMethod(c, sel, imp, method_getTypeEncoding(m));
	if (!added) {
		method_setImplementation(m, imp);
	}
	sb_note([NSString stringWithFormat:@"-[_UIStatusBar layoutSubviews] hooked (%s), diag %d, x %g mode %d",
		added ? "added" : "own", sb_diag, sb_dxx, sb_xmode]);
}

__attribute__((constructor)) static void
sb_init(void)
{
	bool m = sb_flag("/var/local/sweetsb.m", &sb_dxm), t = sb_flag("/var/local/sweetsb.t", &sb_dxt);
	struct stat st;
	/* one shot, SpringBoard only (apps cannot write the log): the flag goes when it is seen, so a bad dump cannot loop */
	sb_diag = strcmp(getprogname(), "SpringBoard") == 0 && stat("/var/local/sweetsb.d", &st) == 0;
	if (sb_diag) {
		unlink("/var/local/sweetsb.d");
	}
	bool x = sb_flag("/var/local/sweetsb.x", &sb_dxx);
	CGFloat xm;
	if (sb_flag("/var/local/sweetsb.xm", &xm) && xm >= 1 && xm <= 3) {
		sb_xmode = (int)xm;
	}
	if (!m && !t && !sb_diag && !x) {
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
	if (sb_diag || x) {
		sb_hook_layout();
	}
}
