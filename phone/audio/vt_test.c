/*
 * vt_test: does VideoToolbox's pixel transfer work in a process without a Metal device and without
 * the iPhone's hardware scaler (AppleM2ScalerCSCDriver)? The camera's preview and photographs go
 * through it in mediaserverd, and came out as zeros (green photographs, a black preview).
 *
 * usage: vt_test   -- 1504x1128 420f with a known pattern, transferred to the same size and format,
 *                     to 752x564 420f, and to 1504x1128 BGRA; prints each status and what came out.
 *        vt_test encode [WIDTH HEIGHT FRAMES [CODEC [ENCODER-ID]]]
 *                  -- redfin (plan B2): VideoToolbox's encoder list, then FRAMES (default 60) moving 1920x1080 420v frames
 *                     encoded in real time as a recording would (CODEC hvc1 or avc1, default both), with the software
 *                     HEVC encoder of VCPHEVC.videocodec registered as mediaserverd registers it: ms a frame, and
 *                     whether 30 fps is kept up. ENCODER-ID: that encoder only (kVTVideoEncoderSpecification_EncoderID).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CVPixelBufferRef
make(int w, int h, OSType f)
{
	CVPixelBufferRef pb = NULL;
	CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	const void *k[] = { kCVPixelBufferIOSurfacePropertiesKey };
	const void *v[] = { empty };
	CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CVReturn r = CVPixelBufferCreate(NULL, w, h, f, attrs, &pb);

	CFRelease(attrs);
	CFRelease(empty);
	if (r != kCVReturnSuccess) {
		printf("vt_test: CVPixelBufferCreate %dx%d %.4s: %d\n", w, h, (char *)&(OSType){ CFSwapInt32HostToBig(f) }, r);
		return NULL;
	}
	return pb;
}

static void
show(const char *what, CVPixelBufferRef pb)
{
	CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	size_t planes = CVPixelBufferGetPlaneCount(pb);
	printf("vt_test: %s: %zux%zu", what, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
	for (size_t p = 0; p < (planes ? planes : 1); p++) {
		const uint8_t *b = planes ? CVPixelBufferGetBaseAddressOfPlane(pb, p) : CVPixelBufferGetBaseAddress(pb);
		size_t stride = planes ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb);
		size_t rows = planes ? CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetHeight(pb);
		unsigned long long sum = 0;
		for (size_t y = 0; y < rows; y++) {
			for (size_t x = 0; x < stride; x += 7) {
				sum += b[y * stride + x];
			}
		}
		printf("; plane %zu mean %.1f, middle %u %u %u %u", p, (double)sum / (rows * ((stride + 6) / 7)),
		    b[rows / 2 * stride + stride / 2], b[rows / 2 * stride + stride / 2 + 1], b[rows / 2 * stride + stride / 2 + 2],
		    b[rows / 2 * stride + stride / 2 + 3]);
	}
	printf("\n");
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

/* ---- redfin (plan B2): encoding speed ---------------------------------------------------------------------------- */

static unsigned encoded, encode_errors;
static size_t encoded_bytes;

static void
encoded_frame(void *ref, void *frame_ref, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
	(void)ref, (void)frame_ref, (void)flags;
	if (status != 0 || sample == NULL) {
		if (encode_errors++ < 3) {
			printf("vt_test: encode: a frame failed (%d)\n", (int)status);
		}
		return;
	}
	encoded++;
	encoded_bytes += CMSampleBufferGetTotalSampleSize(sample);
}

static void
list_encoders(void)
{
	CFArrayRef list = NULL;

	if (VTCopyVideoEncoderList(NULL, &list) != 0 || list == NULL) {
		printf("vt_test: no encoder list\n");
		return;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
		CFDictionaryRef e = CFArrayGetValueAtIndex(list, i);
		CFNumberRef type = CFDictionaryGetValue(e, kVTVideoEncoderList_CodecType);
		CFStringRef id = CFDictionaryGetValue(e, kVTVideoEncoderList_EncoderID);
		CFBooleanRef hw = CFDictionaryGetValue(e, kVTVideoEncoderList_IsHardwareAccelerated);
		uint32_t t = 0;
		char text[160] = "?";

		if (type != NULL) {
			CFNumberGetValue(type, kCFNumberSInt32Type, &t);
		}
		if (id != NULL) {
			CFStringGetCString(id, text, sizeof(text), kCFStringEncodingUTF8);
		}
		printf("vt_test: encoder %c%c%c%c %s%s\n", t >> 24, t >> 16 & 255, t >> 8 & 255, t & 255, text, hw == kCFBooleanTrue ? " (hardware)" : "");
	}
	CFRelease(list);
}

static void
register_vcp_hevc(void)
{
	void *codec = dlopen("/System/Library/VideoCodecs/VCPHEVC.videocodec", RTLD_NOW | RTLD_LOCAL);
	void *create = codec != NULL ? dlsym(codec, "HEVCVideoEncoder_CreateInstance") : NULL;
	int (*register_encoder)(uint32_t, CFDictionaryRef, void *) = dlsym(RTLD_DEFAULT, "VTRegisterVideoEncoderWithInfo");

	if (create == NULL || register_encoder == NULL) {
		printf("vt_test: no VCPHEVC encoder to register\n");
		return;
	}
	const void *keys[] = { kVTVideoEncoderList_EncoderID, kVTVideoEncoderList_EncoderName, kVTVideoEncoderList_IsHardwareAccelerated };
	const void *values[] = { CFSTR("com.apple.videotoolbox.videoencoder.hevc.vcp"), CFSTR("HEVC (VCPHEVC, software)"), kCFBooleanFalse };
	CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

	printf("vt_test: VCPHEVC's encoder registered for hvc1 (%d)\n", register_encoder('hvc1', info, create));
	CFRelease(info);
}

static void
encode(int width, int height, int frames, uint32_t codec, const char *encoder_id)
{
	VTCompressionSessionRef session = NULL;
	CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CVPixelBufferRef pb[4] = { NULL };
	mach_timebase_info_data_t tb;
	uint64_t began, slowest = 0;
	OSStatus st;

	mach_timebase_info(&tb);
	if (encoder_id != NULL) {
		CFStringRef id = CFStringCreateWithCString(NULL, encoder_id, kCFStringEncodingUTF8);

		CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EncoderID, id);
		CFRelease(id);
	}
	st = VTCompressionSessionCreate(NULL, width, height, codec, spec, NULL, NULL, encoded_frame, NULL, &session);
	CFRelease(spec);
	printf("vt_test: encode %c%c%c%c %dx%d: VTCompressionSessionCreate %d\n", codec >> 24, codec >> 16 & 255, codec >> 8 & 255,
	    codec & 255, width, height, (int)st);
	if (st != 0) {
		return;
	}
	VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
	VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
	{
		int32_t bits = width * height * 30 / 8 * 2;     /* (about a phone's: 16 Mbit/s at 1080p) */
		CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &bits);

		VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, n);
		CFRelease(n);
	}
	for (int i = 0; i < 4; i++) {
		pb[i] = make(width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
	}
	encoded = encode_errors = 0;
	encoded_bytes = 0;
	began = mach_absolute_time();
	for (int i = 0; i < frames && pb[i & 3] != NULL; i++) {
		CVPixelBufferRef p = pb[i & 3];
		uint64_t t0 = mach_absolute_time(), t;

		/* a picture that moves: a ramp shifted by the frame's number, noise in the chroma */
		CVPixelBufferLockBaseAddress(p, 0);
		for (int plane = 0; plane < 2; plane++) {
			uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(p, plane);
			size_t stride = CVPixelBufferGetBytesPerRowOfPlane(p, plane), rows = CVPixelBufferGetHeightOfPlane(p, plane);

			for (size_t y = 0; y < rows; y++) {
				for (size_t x = 0; x < stride; x++) {
					b[y * stride + x] = plane == 0 ? (uint8_t)(16 + ((x + y + (size_t)i * 8) & 0xff) * 219 / 255) :
					    (uint8_t)(128 + (int)((x * 2654435761u + y + (size_t)i) >> 28) - 8);
				}
			}
		}
		CVPixelBufferUnlockBaseAddress(p, 0);
		st = VTCompressionSessionEncodeFrame(session, p, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
		if (st != 0) {
			printf("vt_test: encode: frame %d: %d\n", i, (int)st);
			break;
		}
		t = mach_absolute_time() - t0;
		slowest = t > slowest ? t : slowest;
	}
	VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
	double ms = (double)(mach_absolute_time() - began) * tb.numer / tb.denom / 1e6;

	printf("vt_test: encode %c%c%c%c %dx%d: %u of %d frames in %.0f ms: %.1f ms a frame (%.1f fps; slowest call %.1f ms), %zu kB, %u errors\n",
	    codec >> 24, codec >> 16 & 255, codec >> 8 & 255, codec & 255, width, height, encoded, frames, ms,
	    encoded ? ms / encoded : 0, encoded ? encoded * 1000 / ms : 0, (double)slowest * tb.numer / tb.denom / 1e6, encoded_bytes / 1024,
	    encode_errors);
	VTCompressionSessionInvalidate(session);
	CFRelease(session);
	for (int i = 0; i < 4; i++) {
		if (pb[i] != NULL) {
			CVPixelBufferRelease(pb[i]);
		}
	}
}

static int
encode_main(int argc, char **argv)
{
	int width = argc > 2 ? atoi(argv[2]) : 1920, height = argc > 3 ? atoi(argv[3]) : 1080, frames = argc > 4 ? atoi(argv[4]) : 60;
	const char *codec = argc > 5 ? argv[5] : NULL, *id = argc > 6 ? argv[6] : NULL;

	register_vcp_hevc();
	list_encoders();
	if (codec == NULL || strcmp(codec, "hvc1") == 0) {
		encode(width, height, frames, 'hvc1', id);
	}
	if (codec == NULL || strcmp(codec, "avc1") == 0) {
		encode(width, height, frames, 'avc1', id);
	}
	return 0;
}

int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc > 1 && strcmp(argv[1], "encode") == 0) {
		return encode_main(argc, argv);
	}
	CVPixelBufferRef src = make(1504, 1128, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
	if (src == NULL) {
		return 1;
	}
	CVPixelBufferLockBaseAddress(src, 0);
	for (int p = 0; p < 2; p++) {
		uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(src, p);
		size_t stride = CVPixelBufferGetBytesPerRowOfPlane(src, p), rows = CVPixelBufferGetHeightOfPlane(src, p);
		for (size_t y = 0; y < rows; y++) {
			for (size_t x = 0; x < stride; x++) {
				b[y * stride + x] = p == 0 ? (uint8_t)(64 + (x * 128) / stride) : (x & 1) ? 160 : 100;
			}
		}
	}
	CVPixelBufferUnlockBaseAddress(src, 0);
	show("source", src);

	VTPixelTransferSessionRef s = NULL;
	OSStatus st = VTPixelTransferSessionCreate(NULL, &s);
	printf("vt_test: VTPixelTransferSessionCreate %d\n", (int)st);
	if (st != 0) {
		return 1;
	}
	struct { int w, h; OSType f; const char *name; } outs[] = {
		{ 1504, 1128, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "same 420f" },
		{ 752, 564, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "half 420f" },
		{ 1504, 1128, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "same 420v" },
		{ 1504, 1128, kCVPixelFormatType_32BGRA, "same BGRA" },
		{ 3088, 2320, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "up 420f" },
	};
	for (size_t i = 0; i < sizeof(outs) / sizeof(outs[0]); i++) {
		CVPixelBufferRef dst = make(outs[i].w, outs[i].h, outs[i].f);
		if (dst == NULL) {
			continue;
		}
		st = VTPixelTransferSessionTransferImage(s, src, dst);
		printf("vt_test: %s: transfer %d\n", outs[i].name, (int)st);
		show(outs[i].name, dst);
		CVPixelBufferRelease(dst);
	}
	VTPixelTransferSessionInvalidate(s);
	CFRelease(s);
	return 0;
}
