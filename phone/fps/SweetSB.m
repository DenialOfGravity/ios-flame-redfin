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
 *   /var/local/sweetsb.x   DX pt: the leading region (identifier "leading": on iOS 16 a UILayoutGuide in
 *                          _UIStatusBarForegroundView, no container view; its item views sit in the foreground view)
 *                          moves right by DX. How, from the size of /var/local/sweetsb.xm (100 + mode, default 1):
 *                          1 = after -[_UIStatusBarForegroundView layoutSubviews], each leading item view's centre + DX
 *                          2 = after -[_UIStatusBar layoutSubviews], the guide's outside position constraints + DX
 * ws-z-ui3 (user: clock lower and further right, on one line with Wi-Fi/battery, which also come down and in from the
 * right edge). Both use the leading/trailing regions' layout guides (as .x mode 2), so the items stay centred in them:
 *   /var/local/sweetsb.y   size 100 + 2*DY (HALF points; 107 = +3.5 pt): every vertical position constraint between the
 *                          leading or the trailing guide and something outside its region gets DY (positive = down);
 *                          both groups move together and stay on one line
 *   /var/local/sweetsb.r   size 100 + 2*RX (HALF points; 116 = +8 pt): the trailing guide's horizontal position
 *                          constraints move it RX to the LEFT (positive = inward, away from the right screen edge)
 *   (.x stays in whole points; .y/.r work whatever .xm says.) A shifted constraint remembers the constant it was given
 *   and is shifted again only if UIKit later rewrites that constant.
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

static NSArray *
sb_leading_views(UIView *bar, id *rgp)
{
	NSDictionary *regions = sb_get(bar, @"regions");
	if (![regions isKindOfClass:[NSDictionary class]]) {
		return nil;
	}
	id rg = regions[@"leading"];
	if (rgp != NULL) {
		*rgp = rg;
	}
	NSMutableArray *vs = [NSMutableArray array];
	id items = sb_get(rg, @"displayItems");
	if ([items isKindOfClass:[NSDictionary class]]) {
		items = [items allValues];
	}
	for (id it in items) {
		UIView *v = sb_get(it, @"view");
		if ([v isKindOfClass:[UIView class]]) {
			[vs addObject:v];
		}
	}
	return vs;
}

static int sb_noted;

/* mode 1: after the foreground view's own layout pass (Auto Layout has just pushed the item frames), move each
 * leading-region item view's centre right by DX; remember where we put it so a pass that changed nothing is a no-op */
static void
sb_xshift_fg(UIView *fg)
{
	UIView *bar = fg.superview;
	Class sbc = objc_getClass("_UIStatusBar");
	if (bar == nil || sbc == Nil || ![bar isKindOfClass:sbc]) {
		return;
	}
	NSMutableString *what = sb_noted < 4 && fg.window != nil ? [NSMutableString string] : nil;
	for (UIView *v in sb_leading_views(bar, NULL)) {
		if (v.superview == nil) {
			continue;
		}
		NSNumber *mine = objc_getAssociatedObject(v, &sb_xassoc);
		CGPoint c = v.center;
		if (mine == nil || fabs(c.x - mine.doubleValue) > 0.01) {
			c.x += sb_dxx;
			v.center = c;
			objc_setAssociatedObject(v, &sb_xassoc, @(c.x), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		[what appendFormat:@"%@; ", sb_desc(v)];
	}
	if (what.length > 0) {
		sb_noted++;
		sb_note([NSString stringWithFormat:@"x mode 1 (+%g): %@", sb_dxx, what]);
	}
}

/* mode 2 / ws-z-ui3: move a region's layout guide itself: every position constraint on AXIS between the guide and
 * something outside the region (not its item views) gets D (the guide moves +D along the axis). Each constraint keeps
 * {base: UIKit's constant, set: the constant we last wrote, <region.axis>: its delta}: the constant is base + the sum of
 * the deltas, so a constraint between two shifted guides gets both (their relation stays right) without the two passes
 * undoing each other; if UIKit rewrites the constant (!= set), that becomes the new base and the deltas go on again. */
static CGFloat sb_dy, sb_rx;
static char sb_kinfo;

static bool
sb_pos_attr(NSLayoutAttribute a, UILayoutConstraintAxis axis)
{
	if (axis == UILayoutConstraintAxisHorizontal) {
		return a == NSLayoutAttributeLeading || a == NSLayoutAttributeTrailing || a == NSLayoutAttributeLeft
		       || a == NSLayoutAttributeRight || a == NSLayoutAttributeCenterX;
	}
	return a == NSLayoutAttributeTop || a == NSLayoutAttributeBottom || a == NSLayoutAttributeCenterY
	       || a == NSLayoutAttributeFirstBaseline || a == NSLayoutAttributeLastBaseline;
}

static NSArray *
sb_region_views(UIView *bar, NSString *name, id *rgp)
{
	NSDictionary *regions = sb_get(bar, @"regions");
	if (![regions isKindOfClass:[NSDictionary class]]) {
		return nil;
	}
	id rg = regions[name];
	*rgp = rg;
	NSMutableArray *vs = [NSMutableArray array];
	id items = sb_get(rg, @"displayItems");
	if ([items isKindOfClass:[NSDictionary class]]) {
		items = [items allValues];
	}
	for (id it in items) {
		UIView *v = sb_get(it, @"view");
		if ([v isKindOfClass:[UIView class]]) {
			[vs addObject:v];
		}
	}
	return vs;
}

static void
sb_shift_guide(UIView *bar, NSString *name, UILayoutConstraintAxis axis, CGFloat dd)
{
	id rg = nil;
	NSArray *inside = sb_region_views(bar, name, &rg);
	UILayoutGuide *g = sb_get(rg, @"layoutGuide");
	if (dd == 0 || ![g isKindOfClass:[UILayoutGuide class]]) {
		return;
	}
	NSMutableString *what = sb_noted < 12 && bar.window != nil ? [NSMutableString string] : nil;
	NSString *key = [name stringByAppendingString:axis == UILayoutConstraintAxisHorizontal ? @".x" : @".y"];
	for (NSLayoutConstraint *k in [g constraintsAffectingLayoutForAxis:axis]) {
		bool pos1 = sb_pos_attr(k.firstAttribute, axis), pos2 = sb_pos_attr(k.secondAttribute, axis);
		id other = nil;
		CGFloat d = 0;
		if (k.firstItem == g && pos1 && (k.secondItem == nil || pos2)) {
			other = k.secondItem;
			d = dd;
		} else if (k.secondItem == g && pos2 && pos1) {
			other = k.firstItem;
			d = -dd;
		} else {
			continue;
		}
		if (other == g || (other != nil && [inside containsObject:other])) {
			continue;
		}
		NSMutableDictionary *info = objc_getAssociatedObject(k, &sb_kinfo);
		if (info == nil || fabs(k.constant - [info[@"set"] doubleValue]) > 0.001) {
			info = [NSMutableDictionary dictionaryWithObject:@(k.constant) forKey:@"base"];
			objc_setAssociatedObject(k, &sb_kinfo, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		} else if ([info[key] doubleValue] == d) {
			continue;       /* already there */
		}
		info[key] = @(d);
		CGFloat c = [info[@"base"] doubleValue];
		for (NSString *ik in info) {
			if (![ik isEqualToString:@"base"] && ![ik isEqualToString:@"set"]) {
				c += [info[ik] doubleValue];
			}
		}
		k.constant = c;
		info[@"set"] = @(k.constant);
		[what appendFormat:@"%@ ; ", k];
	}
	if (what.length > 0) {
		sb_noted++;
		sb_note([NSString stringWithFormat:@"guide '%@' %s %+g: now %@ via %@", name,
			axis == UILayoutConstraintAxisHorizontal ? "x" : "y", dd, sb_desc(g), what]);
	}
}

static void
sb_xshift_guide(UIView *bar)
{
	sb_shift_guide(bar, @"leading", UILayoutConstraintAxisHorizontal, sb_dxx);
}

static void
sb_after_layout(UIView *bar)
{
	if (sb_dxx != 0 && sb_xmode == 2) {
		sb_xshift_guide(bar);
	}
	if (sb_dy != 0) {
		sb_shift_guide(bar, @"leading", UILayoutConstraintAxisVertical, sb_dy);
		sb_shift_guide(bar, @"trailing", UILayoutConstraintAxisVertical, sb_dy);
	}
	if (sb_rx != 0) {
		sb_shift_guide(bar, @"trailing", UILayoutConstraintAxisHorizontal, -sb_rx);
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
sb_hook_after_layout(const char *cls, void (*after)(UIView *))
{
	Class c = objc_getClass(cls);
	SEL sel = @selector(layoutSubviews);
	Method m = c != Nil ? class_getInstanceMethod(c, sel) : NULL;
	if (m == NULL) {
		sb_note([NSString stringWithFormat:@"no -[%s layoutSubviews]", cls]);
		return;
	}
	void (*old)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
	IMP imp = imp_implementationWithBlock(^(UIView *self) {
		old(self, sel);
		after(self);
	});
	/* add on the class itself when it only inherits UIView's (never hook UIView for every view) */
	bool added = class_addMethod(c, sel, imp, method_getTypeEncoding(m));
	if (!added) {
		method_setImplementation(m, imp);
	}
	sb_note([NSString stringWithFormat:@"-[%s layoutSubviews] hooked (%s), diag %d, x %g mode %d, y %g, r %g", cls,
		added ? "added" : "own", sb_diag, sb_dxx, sb_xmode, sb_dy, sb_rx]);
}

static void
sb_hook_layout(void)
{
	if (sb_diag || (sb_dxx != 0 && sb_xmode == 2) || sb_dy != 0 || sb_rx != 0) {
		sb_hook_after_layout("_UIStatusBar", sb_after_layout);
	}
	if (sb_dxx != 0 && sb_xmode == 1) {
		sb_hook_after_layout("_UIStatusBarForegroundView", sb_xshift_fg);
	}
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
	if (sb_flag("/var/local/sweetsb.xm", &xm) && xm >= 1 && xm <= 2) {
		sb_xmode = (int)xm;
	}
	CGFloat h;
	if (sb_flag("/var/local/sweetsb.y", &h)) {
		sb_dy = h / 2;
	}
	if (sb_flag("/var/local/sweetsb.r", &h)) {
		sb_rx = h / 2;
	}
	bool yr = sb_dy != 0 || sb_rx != 0;
	if (!m && !t && !sb_diag && !x && !yr) {
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
	if (sb_diag || x || yr) {
		sb_hook_layout();
	}
}
