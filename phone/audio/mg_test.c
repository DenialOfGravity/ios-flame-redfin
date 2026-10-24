/*
 * redfin: HackiOS's (MIT), MobileGestalt looked up with dlsym, the camera keys added.
 *
 * mg_test: what MobileGestalt says about this device (the answers iOS builds its idea of the
 * hardware from).   usage: mg_test [KEY...]
 * A key may also be one of the obfuscated names programs ask by; "MGGetProductType" gives the number
 * MGGetProductType() returns (what programs tell the models apart by).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

/* redfin: looked up at run time (the SDK's stubs need not have libMobileGestalt) */
static CFTypeRef (*MGCopyAnswer)(CFStringRef key);
static uint64_t (*MGGetProductType)(void);

static const char *const keys[] = {
	"DeviceClass", "DeviceClassNumber", "DeviceName", "ProductType", "HWModelStr", "ModelNumber", "ProductName",
	"marketing-name", "UserAssignedDeviceName", "ComputerName", "SerialNumber", "UniqueDeviceID", "HasBaseband",
	"telephony", "cellular-data", "wifi", "bluetooth", "DeviceSupportsTelephonyOverUSB", "main-screen-scale",
	"main-screen-width", "main-screen-height", "main-screen-class", "ArtworkDeviceSubType", "DeviceColor", "CPUArchitecture",
	"BuildVersion", "ProductVersion", "RegionInfo", "front-facing-camera", "rear-facing-camera", "still-camera",
	"video-camera", "camera-flash", "auto-focus-camera", "front-facing-camera-auto-focus", "DeviceSupportsCameraCaptureOnLockScreen",
	"CameraCapabilities", "RearFacingCameraCapability", "FrontFacingCameraCapability",
};

int
main(int argc, char **argv)
{
	int count = argc > 1 ? argc - 1 : (int)(sizeof(keys) / sizeof(keys[0]));
	void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);

	MGCopyAnswer = mg ? dlsym(mg, "MGCopyAnswer") : NULL;
	MGGetProductType = mg ? dlsym(mg, "MGGetProductType") : NULL;
	if (MGCopyAnswer == NULL || MGGetProductType == NULL) {
		printf("mg_test: no libMobileGestalt\n");
		return 1;
	}

	for (int i = 0; i < count; i++) {
		const char *name = argc > 1 ? argv[i + 1] : keys[i];
		if (strcmp(name, "MGGetProductType") == 0) {
			printf("mg_test: MGGetProductType() = %#llx\n", (unsigned long long)MGGetProductType());
			continue;
		}
		CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
		CFTypeRef answer = MGCopyAnswer(key);
		CFStringRef text = answer ? CFCopyDescription(answer) : NULL;
		char line[256] = "(none)";

		if (text) {
			CFStringGetCString(text, line, sizeof(line), kCFStringEncodingUTF8);
			CFRelease(text);
		}
		printf("mg_test: %s = %s\n", name, line);
		if (answer) {
			CFRelease(answer);
		}
		CFRelease(key);
	}
	return 0;
}
