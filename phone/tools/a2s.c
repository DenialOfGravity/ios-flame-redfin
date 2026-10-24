/*
 * a2s [ADDR...]: shared-cache addresses (from pstack, any process: one slide per boot) to image and nearest
 * symbol via dladdr, after loading the frameworks a renderer uses. Addresses from stdin without arguments.
 * tools/flame-profile.py-free profiling: pstack samples -> a2s on the phone.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *const libs[] = {
	"/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
	"/System/Library/Frameworks/Metal.framework/Metal",
	"/System/Library/Frameworks/IOSurface.framework/IOSurface",
	"/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
	"/System/Library/Frameworks/CoreImage.framework/CoreImage",
	"/System/Library/Frameworks/Foundation.framework/Foundation",
	"/System/Library/Frameworks/IOKit.framework/IOKit",
	"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
	"/System/Library/PrivateFrameworks/BackBoardHIDEventFoundation.framework/BackBoardHIDEventFoundation",
	"/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
	"/System/Library/PrivateFrameworks/GPUSupport.framework/GPUSupport",
	"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
	"/usr/lib/libobjc.A.dylib",
};

static void one(const char *s)
{
	unsigned long long a = strtoull(s, NULL, 16);
	Dl_info di;
	if (a && dladdr((void *)(uintptr_t)a, &di) && di.dli_fname) {
		const char *img = strrchr(di.dli_fname, '/');
		printf("%s %s %s+0x%llx\n", s, img ? img + 1 : di.dli_fname, di.dli_sname ? di.dli_sname : "?",
		    di.dli_saddr ? a - (unsigned long long)(uintptr_t)di.dli_saddr : a - (unsigned long long)(uintptr_t)di.dli_fbase);
	} else {
		printf("%s ?\n", s);
	}
}

int main(int argc, char **argv)
{
	for (unsigned i = 0; i < sizeof(libs) / sizeof(libs[0]); i++)
		dlopen(libs[i], RTLD_LAZY | RTLD_NOLOAD) || dlopen(libs[i], RTLD_LAZY);
	if (argc > 1) {
		for (int i = 1; i < argc; i++)
			one(argv[i]);
		return 0;
	}
	char line[64];
	while (fgets(line, sizeof(line), stdin)) {
		line[strcspn(line, " \r\n")] = 0;
		if (line[0])
			one(line);
	}
	return 0;
}
