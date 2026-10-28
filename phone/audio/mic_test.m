/*
 * mic_test: records the default input through iOS (AudioQueue, 48 kHz mono S16) and says what it heard.
 *
 * usage: mic_test [SECONDS [FILE.wav]]     (defaults: 5 s, /var/local/tmp/mic.wav)
 *
 * Prints the input the AVAudioSession route and the queue got (device UID, format), then each second's peak
 * and RMS in dBFS, then the whole recording's; writes a 16-bit WAV. Errors are OSStatus values with their
 * fourcc. The path under test: this -> CoreAudio -> RedwoodAudio.driver "Codec" input -> /dev/redwood-mic
 * (kernel mic=1, micgain=N). No entitlements (ad hoc signed like camera_avtest): where TCC refuses the
 * microphone, the permission line and the queue's status say so.
 */
#import <AVFoundation/AVFoundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 48000
#define BUFFERS 8
#define BUFFER_FRAMES 4800   /* 100 ms */

static struct {
	FILE *file;
	uint64_t frames;
	uint64_t sec_frames;     /* frames in the current second */
	double sec_sum;          /* sum of squares, in full-scale units */
	int sec_peak, peak;
	double sum;
	int seconds;
	int callbacks;
} st;

static const char *
fourcc(OSStatus s, char *out)
{
	uint32_t v = (uint32_t)s;
	char c[4] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v };

	if (c[0] >= 32 && c[0] < 127 && c[1] >= 32 && c[1] < 127 && c[2] >= 32 && c[2] < 127 && c[3] >= 32 && c[3] < 127) {
		snprintf(out, 32, "%d '%.4s'", (int)s, c);
	} else {
		snprintf(out, 32, "%d", (int)s);
	}
	return out;
}

static double
db(double x)
{
	return x <= 0 ? -999.0 : 20.0 * log10(x);
}

static void
report(const char *what, double sum, uint64_t n, int peak)
{
	printf("mic_test: %s peak %7.2f dBFS (%5d)  rms %7.2f dBFS\n", what, db(peak / 32768.0), peak,
	    n ? db(sqrt(sum / (double)n)) : -999.0);
}

static void
input(__unused void *ctx, AudioQueueRef q, AudioQueueBufferRef b, __unused const AudioTimeStamp *t, UInt32 packets,
    __unused const AudioStreamPacketDescription *d)
{
	const int16_t *s = b->mAudioData;

	st.callbacks++;
	if (packets > 0) {
		fwrite(s, 2, packets, st.file);
	}
	for (UInt32 i = 0; i < packets; i++) {
		int v = s[i] < 0 ? -s[i] : s[i];
		double f = s[i] / 32768.0;

		st.sec_peak = v > st.sec_peak ? v : st.sec_peak;
		st.sec_sum += f * f;
		st.sec_frames++;
		st.frames++;
		if (st.sec_frames == RATE) {
			char w[32];

			snprintf(w, sizeof w, "second %2d:", ++st.seconds);
			report(w, st.sec_sum, st.sec_frames, st.sec_peak);
			st.peak = st.sec_peak > st.peak ? st.sec_peak : st.peak;
			st.sum += st.sec_sum;
			st.sec_peak = 0;
			st.sec_sum = 0;
			st.sec_frames = 0;
		}
	}
	AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

static void
wav_header(FILE *f, uint32_t bytes)
{
	uint32_t h[11] = { 0x46464952, 36 + bytes, 0x45564157, 0x20746d66, 16, 0x00010001, RATE, RATE * 2, 0x00100002, 0x61746164, bytes };

	fwrite(h, 4, 11, f);   /* RIFF WAVE fmt  PCM mono 48000 16-bit data (little endian) */
}

#define CHECK(call) do { OSStatus e_ = (call); if (e_ != noErr) { char b_[32]; \
	printf("mic_test: %s failed: OSStatus %s\n", #call, fourcc(e_, b_)); return 2; } } while (0)

int
main(int argc, char **argv)
{
	int secs = argc > 1 ? atoi(argv[1]) : 5;
	const char *path = argc > 2 ? argv[2] : "/var/local/tmp/mic.wav";

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (secs < 1 || secs > 600) {
		printf("usage: mic_test [SECONDS (1-600) [FILE.wav]]\n");
		return 1;
	}
	@autoreleasepool {
		AVAudioSession *as = [AVAudioSession sharedInstance];
		NSError *err = nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		long perm = (long)[as recordPermission];   /* 'grnt' granted, 'deny' denied, 'undt' undetermined */
#pragma clang diagnostic pop
		printf("mic_test: record permission %ld ('%.4s'; grnt = granted, deny = denied, undt = not asked)\n", perm,
		    (const char[]){ (char)(perm >> 24), (char)(perm >> 16), (char)(perm >> 8), (char)perm, 0 });
		if (![as setCategory:AVAudioSessionCategoryRecord error:&err] || ![as setActive:YES error:&err]) {
			printf("mic_test: AVAudioSession record category/activate failed: %s (code %ld; continuing)\n",
			    err.localizedDescription.UTF8String, (long)err.code);
			err = nil;
		}
		for (AVAudioSessionPortDescription *p in as.availableInputs) {
			printf("mic_test: available input: %s (%s, uid %s)\n", p.portName.UTF8String, p.portType.UTF8String,
			    p.UID.UTF8String);
		}
		for (AVAudioSessionPortDescription *p in as.currentRoute.inputs) {
			printf("mic_test: route input: %s (%s), session rate %.0f Hz, %ld input channel(s)\n", p.portName.UTF8String,
			    p.portType.UTF8String, as.sampleRate, (long)as.inputNumberOfChannels);
		}

		AudioStreamBasicDescription fmt = { RATE, kAudioFormatLinearPCM,
			kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, 2, 1, 2, 1, 16, 0 };
		AudioQueueRef q;
		AudioQueueBufferRef bufs[BUFFERS];

		st.file = fopen(path, "wb");
		if (!st.file) {
			perror(path);
			return 3;
		}
		wav_header(st.file, 0);
		CHECK(AudioQueueNewInput(&fmt, input, NULL, NULL, NULL, 0, &q));
		for (int i = 0; i < BUFFERS; i++) {
			CHECK(AudioQueueAllocateBuffer(q, BUFFER_FRAMES * 2, &bufs[i]));
			CHECK(AudioQueueEnqueueBuffer(q, bufs[i], 0, NULL));
		}
		CFStringRef uid = NULL;
		UInt32 size = sizeof uid;
		AudioStreamBasicDescription got;
		UInt32 gsize = sizeof got;

		if (AudioQueueGetProperty(q, kAudioQueueProperty_CurrentDevice, &uid, &size) == noErr && uid) {
			printf("mic_test: queue device: %s\n", ((__bridge NSString *)uid).UTF8String);
			CFRelease(uid);
		}
		if (AudioQueueGetProperty(q, kAudioQueueProperty_StreamDescription, &got, &gsize) == noErr) {
			printf("mic_test: queue format: %.0f Hz, %u ch, %u-bit, flags %#x\n", got.mSampleRate, (unsigned)got.mChannelsPerFrame,
			    (unsigned)got.mBitsPerChannel, (unsigned)got.mFormatFlags);
		}
		printf("mic_test: recording %d s to %s\n", secs, path);
		CHECK(AudioQueueStart(q, NULL));
		CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + secs + 0.2;
		while (CFAbsoluteTimeGetCurrent() < end) {
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
		}
		AudioQueueStop(q, true);
		AudioQueueDispose(q, true);
		if (st.sec_frames) {
			st.peak = st.sec_peak > st.peak ? st.sec_peak : st.peak;
			st.sum += st.sec_sum;
		}
		uint64_t total = (uint64_t)st.seconds * RATE + st.sec_frames;

		if (st.callbacks == 0 || total == 0) {
			printf("mic_test: NO SAMPLES arrived (%d callbacks): check the kernel (mic=1, sndgpio=1, adsp=1), "
			       "RedwoodAudio.driver and the TCC permission above\n", st.callbacks);
		}
		fseek(st.file, 0, SEEK_SET);
		wav_header(st.file, (uint32_t)(total * 2));
		fclose(st.file);
		printf("mic_test: %llu frames (%.2f s) in %d callbacks\n", (unsigned long long)total, total / (double)RATE, st.callbacks);
		report("total:   ", st.sum, total, st.peak);
		if (total > 0 && st.peak == 0) {
			printf("mic_test: all samples are exactly 0 (a muted or dead path)\n");
		}
		return total > 0 ? 0 : 4;
	}
}
