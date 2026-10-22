/*
 * imgtest: decode images with ImageIO and report whether the pixels are real.
 *   imgtest FILE...
 * Per file: the decoded CGImage's size/bpc/alpha info, the sum of its own bytes
 * (CGDataProviderCopyData), and the sum after drawing it into an RGBA bitmap.
 * Zero sums mean the decode produced nothing (e.g. HEIC without a HEVC decoder).
 */
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, char **argv)
{
	@autoreleasepool {
		for (int i = 1; i < argc; i++) {
			NSURL *u = [NSURL fileURLWithPath:@(argv[i])];
			CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)u, NULL);
			if (!src) {
				printf("%s: no image source\n", argv[i]);
				continue;
			}
			CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
			CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
			double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
			if (!img) {
				printf("%s: type %s, decode failed (%.0f ms)\n", argv[i],
				       [(__bridge NSString *)CGImageSourceGetType(src) UTF8String], ms);
				CFRelease(src);
				continue;
			}
			size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
			CFDataRef raw = CGDataProviderCopyData(CGImageGetDataProvider(img));
			uint64_t rsum = 0;
			const uint8_t *rp = raw ? CFDataGetBytePtr(raw) : NULL;
			for (CFIndex k = 0; rp && k < CFDataGetLength(raw); k++)
				rsum += rp[k];
			uint8_t *px = calloc(w * h, 4);
			CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
			CGContextRef c = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
			CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
			uint64_t sum[4] = { 0 };
			for (size_t k = 0; k < w * h; k++)
				for (int ch = 0; ch < 4; ch++)
					sum[ch] += px[4 * k + ch];
			printf("%s: type %s %zux%zu bpc %zu alpha %u, decode %.0f ms, raw %ld bytes sum %llu, "
			       "drawn mean RGBA %.1f %.1f %.1f %.1f\n", argv[i],
			       [(__bridge NSString *)CGImageSourceGetType(src) UTF8String], w, h, CGImageGetBitsPerComponent(img),
			       (unsigned)CGImageGetAlphaInfo(img), ms, raw ? (long)CFDataGetLength(raw) : -1L,
			       (unsigned long long)rsum, sum[0] / (double)(w * h), sum[1] / (double)(w * h),
			       sum[2] / (double)(w * h), sum[3] / (double)(w * h));
			CGContextRelease(c);
			CGColorSpaceRelease(cs);
			free(px);
			if (raw)
				CFRelease(raw);
			CGImageRelease(img);
			CFRelease(src);
		}
	}
	return 0;
}
