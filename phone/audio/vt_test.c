/*
 * vt_test: does VideoToolbox's pixel transfer work in a process without a Metal device and without
 * the iPhone's hardware scaler (AppleM2ScalerCSCDriver)? The camera's preview and photographs go
 * through it in mediaserverd, and came out as zeros (green photographs, a black preview).
 *
 * usage: vt_test   -- 1504x1128 420f with a known pattern, transferred to the same size and format,
 *                     to 752x564 420f, and to 1504x1128 BGRA; prints each status and what came out.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stdio.h>
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

int
main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
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
