/*
 * SweetMetal2.bundle: the Metal driver for the Adreno 640 on metal2vulkan + Turnip (boot-arg sweetmtl=2: the kernel's
 * SweetAccelerator names this bundle and class SweetMTL2Device). Metal.framework loads it in every process that asks
 * for a device; -initWithAcceleratorPort: hands back the frontend's device (NativeBridgeMetalFrontend.mm, UniXNU's,
 * over the bridge in bridge/, which drives Turnip, the libvulkan_freedreno.dylib inside this bundle, through the
 * kernel's v2 user client). Which processes get one: backboardd always, others when /var/local/mtl2-clients lists
 * them ("*" = all, "-NAME" excludes NAME); the rest get none, so their frameworks take their CPU paths.
 * Log: /dev/console and /var/local/mtl2.log (when it exists, mode 666), lines "MTL2[pid name]: ...".
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include "NativeBridgeMetalFrontend.h"
#include "bridge/NativeMetalObjects.h"

extern "C" void sm2_logs(const char *s)
{
	char buf[1500];	/* u-t: the T 5s line runs to ~800 (u-perfctr: T tu-perf lines up to 1400) */
	int n = snprintf(buf, sizeof(buf), "MTL2[%d %s]: %s\n", getpid(), getprogname(), s);
	if (n > (int)sizeof(buf) - 1)
		n = (int)sizeof(buf) - 1;
	static int console = -2, file = -2;
	if (console == -2)
		console = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (file == -2)
		file = open("/var/local/mtl2.log", O_WRONLY | O_APPEND);
	if (console >= 0)
		write(console, buf, (size_t)n);
	if (file >= 0)
		write(file, buf, (size_t)n);
}

static void sm2_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sm2_log(const char *fmt, ...)
{
	char buf[600];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	sm2_logs(buf);
}

/*
 * The A640 does not snoop the CPU caches: libSystem's sys_dcache_flush (a no-op where the GPU is coherent) must
 * really clean and invalidate here. User space may (SCTLR_EL1.UCI). This definition wins at link time, for the
 * bridge and the frontend alike (IOSurface imports).
 */
extern "C" void sys_dcache_flush(void *start, size_t len)
{
	uintptr_t a = (uintptr_t)start & ~(uintptr_t)63, end = (uintptr_t)start + len;
	for (; a < end; a += 64)
		__asm__ volatile("dc civac, %0" :: "r"(a) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

/* Metal validation failures abort by default; frameworks with Apple-GPU-only kernels (MPS) report one on any other device. */
__attribute__((constructor)) static void sm2_error_mode(void)
{
	void (*set)(unsigned, unsigned) = (void (*)(unsigned, unsigned))dlsym(RTLD_DEFAULT, "MTLFailureTypeSetErrorModeType");
	for (unsigned t = 0; set && t < 5; t++)
		set(t, 5);	/* 5 = NSLog */
}

/* Selectors the frontend lacks, each logged once (the frontend then raises the usual unrecognised-selector exception) */
static void missing(const char *cls, const char *sel)
{
	static NSMutableSet *seen;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		seen = [NSMutableSet new];
	});
	NSString *k = [NSString stringWithFormat:@"%s %s", cls, sel];
	@synchronized(seen) {
		if ([seen containsObject:k])
			return;
		[seen addObject:k];
	}
	sm2_log("MISSING %s -%s", cls, sel);
}

@interface NBDeviceMethods : NSObject
@end

/* iOS 16's QuartzCore asks for its precompiled pipeline archive (Apple GPU code): none, it builds its pipelines itself. */
@interface NBDeviceMethods (SweetMetal2)
@end
@implementation NBDeviceMethods (SweetMetal2)
- (id)newPipelineLibraryWithFilePath:(NSString *)path error:(NSError **)error
{
	if (error)
		*error = [NSError errorWithDomain:@"SweetMetal2" code:1 userInfo:@{ NSLocalizedDescriptionKey : @"no pipeline libraries" }];
	return nil;
}
@end

static bool listed(void)
{
	if (!strcmp(getprogname(), "backboardd"))
		return true;
	FILE *f = fopen("/var/local/mtl2-clients", "r");
	if (!f)
		return false;
	char text[2048] = { 0 };
	size_t n = fread(text, 1, sizeof(text) - 1, f);
	fclose(f);
	text[n] = 0;
	/* names, "*" = all, "-NAME" = never NAME (wins over "*") */
	char *save = NULL;
	bool yes = false;
	for (char *name = strtok_r(text, " ,\t\r\n", &save); name; name = strtok_r(NULL, " ,\t\r\n", &save)) {
		if (name[0] == '-' && !strcmp(name + 1, getprogname()))
			return false;
		if (!strcmp(name, "*") || !strcmp(name, getprogname()))
			yes = true;
	}
	return yes;
}

@interface _MTLDevice : NSObject
@end

@interface SweetMTL2Device : _MTLDevice
- (id)initWithAcceleratorPort:(mach_port_t)port;
@end

@implementation SweetMTL2Device
- (id)initWithAcceleratorPort:(mach_port_t)port
{
	/* this object is dropped for the frontend's device: initialised, so its -[_MTLDevice dealloc] has queues to release */
	if (!(self = [super init]))
		return nil;
	static id device;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		if (!listed()) {
			sm2_log("not listed (/var/local/mtl2-clients): no Metal device");
			return;
		}
		/* Turnip's per-name BO census (TU_DEBUG=bos, every 300 submits: phone/turnip/patches/0101) into
		 * /var/local/tubos/NAME-PID.log while /var/local/tubos exists (mode 777) */
		if (access("/var/local/tubos", W_OK) == 0) {
			char log[256];
			snprintf(log, sizeof(log), "/var/local/tubos/%s-%d.log", getprogname(), getpid());
			setenv("TU_DEBUG", "bos", 1);
			setenv("MESA_LOG_FILE", log, 1);
			sm2_log("BO census -> %s", log);
		}
		NSString *bundle = [[NSBundle bundleForClass:[SweetMTL2Device class]] bundlePath];
		NSString *turnip = [bundle stringByAppendingPathComponent:@"libvulkan_freedreno.dylib"];
		char cache[256];
		mkdir("/var/local/m2v-cache", 0777);
		chmod("/var/local/m2v-cache", 0777);
		snprintf(cache, sizeof(cache), "/var/local/m2v-cache/%s", getprogname());
		mkdir(cache, 0777);
		if (access(cache, W_OK) != 0) {
			/* a sandboxed process: its own caches directory */
			char dir[256];
			if (confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof(dir) - 8)) {
				snprintf(cache, sizeof(cache), "%sm2v", dir);
				mkdir(cache, 0700);
			}
		}
		/* plain rows everywhere: no Apple framebuffer compression, no 10-bit deep framebuffer */
		setenv("CA_DISABLE_FRAMEBUFFER_COMPRESSION", "1", 1);
		CFPreferencesSetAppValue(CFSTR("CAEnableFramebufferCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableIOSurfaceCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		CFPreferencesSetAppValue(CFSTR("CAEnableDeepFramebuffer"), kCFBooleanFalse, kCFPreferencesCurrentApplication);
		/* the runtime's VkPipeline makings count into the telemetry (V row) */
		setenv("METAL2VULKAN_LOG_PIPELINES", "1", 0);
		/* u-t (r31): backboardd's frame timeline ("native-metal: T 5s" lines, Turnip's pass times) on unless
		 * /var/local/mtl2-env says SWEET_TIMELINE=0; the shadow-copy repack (bridge 0104) off unless it says
		 * SWEET_SHADOW_REPACK=1 (it changed nothing measurable); SWEET_TU_GPU_WAIT=1 lets Turnip leave its
		 * waits on submitted fences to the GPU (phone/turnip/patches/0105) */
		if (!strcmp(getprogname(), "backboardd"))
			setenv("SWEET_TIMELINE", "1", 0);
		setenv("SWEET_SHADOW_REPACK", "0", 0);
		/* debugging: KEY=VALUE lines of /var/local/mtl2-env into this process's environment */
		if (FILE *ef = fopen("/var/local/mtl2-env", "r")) {
			char line[256];
			while (fgets(line, sizeof(line), ef)) {
				line[strcspn(line, "\r\n")] = 0;
				char *eq = strchr(line, '=');
				if (line[0] != '#' && eq) {
					*eq = 0;
					setenv(line, eq + 1, 1);
					sm2_log("env %s=%s", line, eq + 1);
				}
			}
			fclose(ef);
		}
		/* r34: Mesa's shader disk cache (Turnip is built with it) in this process's m2v cache directory: compiled ir3 shaders are
		 * found across restarts even where the runtime's per-making VkPipelineCache records miss. SWEET_MESA_CACHE=0 turns it off. */
		{
			const char *knob = getenv("SWEET_MESA_CACHE");
			if (knob && !strcmp(knob, "0")) {
				setenv("MESA_SHADER_CACHE_DISABLE", "true", 1);
				sm2_log("Mesa shader cache off (SWEET_MESA_CACHE=0)");
			} else {
				char mesa[300];
				snprintf(mesa, sizeof(mesa), "%s/mesa", cache);
				mkdir(mesa, 0777);
				setenv("MESA_SHADER_CACHE_DIR", mesa, 0);
				setenv("MESA_SHADER_CACHE_MAX_SIZE", "256M", 0);
				setenv("MESA_SHADER_CACHE_DISABLE", "false", 0);
				sm2_log("Mesa shader cache %s (%s)", getenv("MESA_SHADER_CACHE_DIR"), access(mesa, W_OK) == 0 ? "writable" : "NOT writable");
			}
		}
		/* debugging: Turnip options for this process from /var/local/mtl2-tu-debug (TU_DEBUG), its log to /var/local/turnip-<proc>.log */
		{
			char opts[128] = { 0 };
			FILE *f = fopen("/var/local/mtl2-tu-debug", "r");
			if (f) {
				if (fgets(opts, sizeof(opts), f))
					opts[strcspn(opts, "\r\n")] = 0;
				fclose(f);
			}
			if (opts[0]) {
				char path[128];
				snprintf(path, sizeof(path), "/var/local/turnip-%s.log", getprogname());
				setenv("TU_DEBUG", opts, 1);
				setenv("MESA_LOG_FILE", path, 1);
				sm2_log("TU_DEBUG=%s, log %s", opts, path);
			}
		}
		uint64_t registryID = 0;
		IORegistryEntryGetRegistryEntryID(port, &registryID);
		double t0 = CFAbsoluteTimeGetCurrent();
		/*
		 * rotfb3: a relaunched backboardd opened its device while the kernel was still freeing the crashed one's GPU pool
		 * (r62b: "device refused: device: OutOfMemory(Device)" at 3979.2 s, the old client's 438 MB freed by 3983.2 s), and
		 * stayed on Core Animation's CPU renderer. An OutOfMemory refusal is tried again, once a second, up to 8 times.
		 */
		for (int attempt = 0; attempt < 9; attempt++) {
			@try {
				device = native_bridge_metal_open(turnip.UTF8String, cache, registryID, missing);
			} @catch (NSException *e) {
				sm2_log("device: exception %s", e.reason.UTF8String);
				device = nil;
			}
			if (device || !strstr(nmb_last_error(), "OutOfMemory") || attempt == 8)
				break;
			sm2_log("device refused (%s): again in 1 s (%d of 8)", nmb_last_error(), attempt + 1);
			sleep(1);
		}
		sm2_log("device %s in %.0f ms (cache %s)%s%s", device ? [[device name] UTF8String] : "refused",
			(CFAbsoluteTimeGetCurrent() - t0) * 1000, cache, device ? "" : ": ", device ? "" : nmb_last_error());
		/*
		 * Extended-range (XR10) formats: the frontend withholds them so backboardd keeps an 8-bit framebuffer; other
		 * processes may render into them (AegirPoster's CAMetalLayer throws "unsupported extended range format" without).
		 */
		if (device && strcmp(getprogname(), "backboardd") != 0)
			class_replaceMethod(object_getClass(device), sel_registerName("supportsExtendedXR10Formats"),
					    imp_implementationWithBlock(^BOOL(id me) { (void)me; return YES; }), "B16@0:8");
		/*
		 * Render-target rotation: _MTLDevice answers YES, so Core Animation draws its landscape framebuffer as a
		 * rotated (rotation 1/3) texture over the portrait panel surface. metal2vulkan holds such a texture through a
		 * shadow image and a rotation kernel copy in and out of every pass: ~220 ms of GPU a frame on the Adreno 620
		 * (r62b: GPU 99% busy, 30-60 of 60 frames a second dropped, landscape after ~10 s with no animation). Answering
		 * NO makes CA keep the portrait framebuffer and rotate in its own composite, as on GPUs without the feature.
		 * /var/local/mtl2-env SWEET_RT_ROTATION=1 keeps Metal's answer.
		 */
		const char *rt = getenv("SWEET_RT_ROTATION");
		if (device && !(rt && atoi(rt))) {
			class_replaceMethod(object_getClass(device), sel_registerName("supportsRenderTargetTextureRotation"),
					    imp_implementationWithBlock(^BOOL(id me) { (void)me; return NO; }), "B16@0:8");
			sm2_log("render-target rotation: answered NO (SWEET_RT_ROTATION=1 keeps Metal's)");
		}
		/* image bases, for symbolicating pstack samples (atos -o out/SweetMetal2.dSYM -l BASE ADDR) */
		Dl_info self = { 0 }, tu = { 0 };
		dladdr((void *)sm2_logs, &self);
		void *th = dlopen(turnip.UTF8String, RTLD_NOW | RTLD_NOLOAD);
		void *vk = th ? dlsym(th, "vk_icdGetInstanceProcAddr") : NULL;
		if (vk)
			dladdr(vk, &tu);
		sm2_log("images: SweetMetal2 %p, libvulkan_freedreno %p", self.dli_fbase, tu.dli_fbase);
		/* u-t: Turnip's pass timeline report (phone/turnip/patches/0105) for the frontend's T line */
		if (th) {
			native_bridge_metal_pass_report = (size_t (*)(char *, size_t, unsigned))dlsym(th, "sweet_tu_pass_report");
			/* u-tr: Turnip's CPU profile (phone/turnip/patches/0110, SWEET_TU_CPUPROF=1) */
			native_bridge_metal_cpu_report = (size_t (*)(char *, size_t))dlsym(th, "sweet_tu_cpu_report");
			/* u-ub: Turnip's UBWC census (phone/turnip/patches/0111; SWEET_UBWC from /var/local/mtl2-env) */
			native_bridge_metal_ubwc_report = (size_t (*)(char *, size_t))dlsym(th, "sweet_tu_ubwc_report");
			native_bridge_metal_draw_report = (size_t (*)(char *, size_t))dlsym(th, "sweet_tu_draw_report");
			/* u-perfctr: Turnip 0113's hardware counters (SWEET_TU_PERFCTR=<preset>) */
			native_bridge_metal_perf_report = (size_t (*)(char *, size_t, unsigned))dlsym(th, "sweet_tu_perf_report");
			if (!native_bridge_metal_pass_report && !strcmp(getprogname(), "backboardd"))
				sm2_log("timeline: sweet_tu_pass_report not exported by Turnip: no pass times");
		}
		/* backboardd: the frontend's counters every 10 s, into /var/local/mtl2.log only (with /var/local/mtl2-telemetry) */
		if (device && !strcmp(getprogname(), "backboardd"))
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				for (;;) {
					sleep(10);
					if (access("/var/local/mtl2-telemetry", F_OK) != 0)
						continue;
					static char text[8192];
					native_bridge_metal_telemetry(text, sizeof(text));
					int fd = open("/var/local/mtl2.log", O_WRONLY | O_APPEND | O_CREAT, 0666);	/* made if missing (r19a had none) */
					if (fd >= 0) {
						dprintf(fd, "MTL2[%d %s]: telemetry\n%s", getpid(), getprogname(), text);
						close(fd);
					}
				}
			});
	});
	return device;
}
@end
