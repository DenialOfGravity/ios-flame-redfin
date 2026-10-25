/*
 * isp_hosttest: camera_isp.c's AE, AWB and pictures checked on the build machine (not on the phone), with a
 * simulated sensor and kernel: frames of a known scene in MIPI RAW10, the kernel's clamping of what AE asks
 * (the IMX363's 8x analog gain), a delay of two frames before an exposure takes effect.
 *
 *   cc -O2 -Wall -I. isp_hosttest.c camera_isp.c -lm -o /tmp/isp_hosttest && /tmp/isp_hosttest
 *
 * Not part of build.sh (nothing of it goes to the phone).
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "camera_isp.h"

static int failures;

#define CHECK(what, ...) do { if (!(what)) { failures++; printf("FAIL %s:%d: %s: ", __FILE__, __LINE__, #what); \
	printf(__VA_ARGS__); printf("\n"); } } while (0)

struct sim {
	struct redwood_camera_frame f;
	uint8_t *raw;
	double light;                   /* the scene: a grey's level at 1 line and 1x */
	uint32_t pending_lines[3], pending_gain[3], pending_frame[3];    /* what the kernel will set, two frames on */
	uint32_t dgain_unity, dgain_max;
};

static void
pack(uint8_t *line, uint32_t x, int v)
{
	uint8_t *g = line + (x >> 2) * 5;
	int i = (int)(x & 3);

	v = v < 0 ? 0 : v > 1023 ? 1023 : v;
	g[i] = (uint8_t)(v >> 2);
	g[4] = (uint8_t)((g[4] & ~(3 << (i * 2))) | ((v & 3) << (i * 2)));
}

/* a frame of the scene: a grey ramp left to right with a colour cast (R 0.5, B 0.7 of green), BGGR */
static void
sim_frame(struct sim *s)
{
	struct redwood_camera_frame *f = &s->f;
	double expo = f->exposure_lines * (double)f->gain / f->gain_unity;

	for (uint32_t y = 0; y < f->height; y++) {
		uint8_t *line = s->raw + (size_t)y * f->stride;

		for (uint32_t x = 0; x < f->width; x++) {
			double ramp = 0.3 + 1.4 * x / f->width, cast = (y & 1) == 0 && (x & 1) == 0 ? 0.7 : (y & 1) && (x & 1) ? 0.5 : 1;

			pack(line, x, 64 + (int)(s->light * ramp * cast * expo));
		}
	}
	f->sequence++;
}

static void
sim_init(struct sim *s, uint32_t width, uint32_t height, double light)
{
	memset(s, 0, sizeof(*s));
	memcpy(s->f.magic, REDWOOD_CAMERA_MAGIC, 8);
	s->f.header_bytes = sizeof(s->f);
	s->f.width = width;
	s->f.height = height;
	s->f.stride = (width * 10 / 8 + 15) & ~15u;
	s->f.format = 1;
	s->f.bayer = 3;
	s->f.black = 64;
	s->f.line_ns = 10000;           /* 10 us a line: 3333 lines a 30 fps frame */
	s->f.frame_lines_min = 3333;
	s->f.frame_lines = 3333;
	s->f.frame_lines_max = 65535;
	s->f.margin = 20;
	s->f.gain_unity = 256;
	s->f.gain_max = 8 * 256;        /* the IMX363's */
	s->f.gain = 256;
	s->f.exposure_lines = 1000;
	s->f.sensor = 1;
	s->f.focus = REDWOOD_CAMERA_NO_FOCUS;
	s->light = light;
	s->raw = calloc(1, (size_t)s->f.stride * height);
	for (int i = 0; i < 3; i++) {
		s->pending_lines[i] = s->f.exposure_lines;
		s->pending_gain[i] = s->f.gain;
		s->pending_frame[i] = s->f.frame_lines;
	}
}

/* the kernel: clamps and echoes what it set, two frames after it was asked */
static void
sim_command(struct sim *s, const struct redwood_camera_command *c)
{
	uint32_t gain = c->b > s->f.gain_max ? s->f.gain_max : c->b < s->f.gain_unity ? s->f.gain_unity : c->b;
	uint32_t frame = c->c ? c->c : s->f.frame_lines_min;
	uint32_t lines = c->a;

	frame = frame < lines + s->f.margin ? lines + s->f.margin : frame;
	frame = frame > s->f.frame_lines_max ? s->f.frame_lines_max : frame;
	lines = lines > frame - s->f.margin ? frame - s->f.margin : lines;
	s->pending_lines[2] = lines;
	s->pending_gain[2] = gain;
	s->pending_frame[2] = frame;
}

static void
sim_step(struct sim *s)
{
	s->f.exposure_lines = s->pending_lines[0];
	s->f.gain = s->pending_gain[0];
	s->f.frame_lines = s->pending_frame[0];
	for (int i = 0; i < 2; i++) {
		s->pending_lines[i] = s->pending_lines[i + 1];
		s->pending_gain[i] = s->pending_gain[i + 1];
		s->pending_frame[i] = s->pending_frame[i + 1];
	}
	sim_frame(s);
}

/* n frames of AE and AWB; how many commands were given */
static int
run(struct sim *s, struct isp *isp, int n, struct isp_stats *st, uint32_t *last_frame_lines)
{
	int commands = 0;

	for (int i = 0; i < n; i++) {
		struct redwood_camera_command c;

		sim_step(s);
		isp_measure(isp, &s->f, s->raw, st);
		isp_awb(isp, st);
		if (isp_ae(isp, &s->f, st, &c)) {
			commands++;
			if (last_frame_lines != NULL) {
				*last_frame_lines = c.c;
			}
			sim_command(s, &c);
		}
	}
	return commands;
}

static void
test_ae_dark_does_not_freeze(void)
{
	struct sim s;
	struct isp isp;
	struct isp_stats st;

	/* so dark that 15 % of white needs more than 8x at the longest frame: the old AE asked for 16x and froze */
	sim_init(&s, 640, 480, 0.0004);
	isp_init(&isp);
	isp.max_frame_lines = 3333 * 2;
	run(&s, &isp, 200, &st, NULL);
	CHECK(s.f.gain == s.f.gain_max, "gain %u, max %u", s.f.gain, s.f.gain_max);
	CHECK(isp.digital > 1.05f, "digital %.2f: the processor's gain should make up what the sensor cannot", isp.digital);
	CHECK(!isp.asked || isp.asked_frames < AE_PATIENCE, "AE still waiting after %u frames", isp.asked_frames);
	CHECK(s.f.exposure_lines == 3333 * 2 - 20, "exposure %u lines (the longest frame's)", s.f.exposure_lines);
	printf("dark: %u lines, gain %.2fx, digital %.2fx, green %.0f\n", s.f.exposure_lines, s.f.gain / 256.0, isp.digital, st.mean[1]);

	/* the light comes back: AE gets out of it again */
	s.light = 0.01;
	run(&s, &isp, 200, &st, NULL);
	CHECK(fabs(st.mean[1] * isp.digital / (0.15 * 959) - 1) < 0.12, "green %.0f x %.2f, target %.0f", st.mean[1], isp.digital,
	    0.15 * 959);
	CHECK(isp.ae_stable, "not stable");
}

static void
test_ae_bright(void)
{
	struct sim s;
	struct isp isp;
	struct isp_stats st;

	sim_init(&s, 640, 480, 0.2);
	isp_init(&isp);
	run(&s, &isp, 120, &st, NULL);
	CHECK(fabs(st.mean[1] * isp.digital / (0.15 * 959) - 1) < 0.12, "green %.0f, target %.0f", st.mean[1], 0.15 * 959);
	CHECK(s.f.gain == 256, "gain %u in daylight", s.f.gain);
	CHECK(isp.ae_stable, "not stable");
}

static void
test_ae_controls(void)
{
	struct sim s;
	struct isp isp;
	struct isp_stats st;
	double base;
	uint32_t frame_lines = 0;

	sim_init(&s, 640, 480, 0.02);
	isp_init(&isp);
	run(&s, &isp, 120, &st, NULL);
	base = st.mean[1] * isp.digital;

	/* +1 EV */
	isp.ae_bias = 1;
	run(&s, &isp, 120, &st, NULL);
	CHECK(fabs(st.mean[1] * isp.digital / base - 2) < 0.25, "bias +1: green %.0f against %.0f", st.mean[1] * isp.digital, base);
	isp.ae_bias = 0;
	run(&s, &isp, 120, &st, NULL);

	/* locked: no command whatever the light does */
	isp.ae_locked = true;
	s.light *= 3;
	CHECK(run(&s, &isp, 40, &st, NULL) == 0, "locked AE gave commands");
	isp.ae_locked = false;
	CHECK(run(&s, &isp, 120, &st, NULL) > 0, "unlocked AE gave no command");

	/* metering on the left (darker) third: brighter overall than metering the whole */
	base = st.mean[1] * isp.digital;
	isp.ae_roi[0] = 0;
	isp.ae_roi[1] = 0;
	isp.ae_roi[2] = 0.2f;
	isp.ae_roi[3] = 1;
	run(&s, &isp, 120, &st, NULL);
	CHECK(st.roi_cells > 0 && st.mean[1] * isp.digital > base * 1.3, "ROI on the dark side: green %.0f against %.0f (roi %.0f)",
	    st.mean[1] * isp.digital, base, st.roi_mean[1]);
	memset(isp.ae_roi, 0, sizeof(isp.ae_roi));

	/* the frame rate kept at 24 or less: every command's frame lines at least 1e9 / 24 / 10000 */
	isp.min_frame_lines = 4167;
	s.light = 0.0004;
	run(&s, &isp, 100, &st, &frame_lines);
	CHECK(frame_lines >= 4167, "frame lines %u asked with a 24 fps limit", frame_lines);

	/* the most gain: 2x */
	isp.ae_max_gain = 2;
	isp.max_frame_lines = 3333;
	run(&s, &isp, 100, &st, NULL);
	CHECK(s.f.gain / 256.0 * isp.sensor_digital * isp.digital <= 2.01, "gain %.2f x %.2f with AEMaxGain 2", s.f.gain / 256.0,
	    isp.digital);
	isp.ae_max_gain = 0;

	/* the longest exposure: 5 ms */
	isp.ae_max_exposure_us = 5000;
	run(&s, &isp, 100, &st, NULL);
	CHECK(s.f.exposure_lines <= 500, "exposure %u lines with MaxIntegrationTime 5 ms", s.f.exposure_lines);
	isp.ae_max_exposure_us = 0;

	/* custom: 1/100 s at 4x */
	isp.manual = true;
	isp.manual_us = 10000;
	isp.manual_gain = 4;
	run(&s, &isp, 30, &st, NULL);
	CHECK(s.f.exposure_lines == 1000 && s.f.gain == 1024, "custom exposure: %u lines at %u", s.f.exposure_lines, s.f.gain);
	CHECK(run(&s, &isp, 20, &st, NULL) == 0, "a custom exposure that is there asked again");
	isp.manual = false;
}

static void
test_ae_sensor_digital(void)
{
	struct sim s;
	struct isp isp;
	struct isp_stats st;

	sim_init(&s, 640, 480, 0.0004);
	s.f.reserved[REDWOOD_CAMERA_R_DGAIN] = 256 | (16 * 256) << 16;  /* 1x to 16x */
	isp_init(&isp);
	isp.max_frame_lines = 3333 * 2;
	/* (the simulated kernel does not apply digital gain to the levels: the check is only that it is asked) */
	struct redwood_camera_command c;
	bool asked_d = false;

	for (int i = 0; i < 100; i++) {
		sim_step(&s);
		isp_measure(&isp, &s.f, s.raw, &st);
		if (isp_ae(&isp, &s.f, &st, &c)) {
			asked_d |= c.d > 256;
			sim_command(&s, &c);
		}
	}
	CHECK(asked_d, "the sensor's digital gain was never asked for");
}

static void
test_awb_lock(void)
{
	struct sim s;
	struct isp isp;
	struct isp_stats st;

	sim_init(&s, 640, 480, 0.02);
	isp_init(&isp);
	run(&s, &isp, 100, &st, NULL);
	CHECK(fabsf(isp.wb[0] - 2.0f) < 0.15f && fabsf(isp.wb[2] - 1 / 0.7f) < 0.15f, "white balance R %.2f B %.2f (2.0, 1.43)",
	    isp.wb[0], isp.wb[2]);
	isp.awb_locked = true;
	isp.wb[0] = 1.5f;
	run(&s, &isp, 20, &st, NULL);
	CHECK(isp.wb[0] == 1.5f, "locked white balance moved to %.2f", isp.wb[0]);
	isp.awb_locked = false;
	isp.awb_manual = true;
	isp.wb_manual[0] = 1.2f;
	isp.wb_manual[1] = 1;
	isp.wb_manual[2] = 2.5f;
	run(&s, &isp, 5, &st, NULL);
	CHECK(isp.wb[0] == 1.2f && isp.wb[2] == 2.5f, "manual white balance R %.2f B %.2f", isp.wb[0], isp.wb[2]);
}

/* the integer pictures (B8) against the float ones: at most a step apart, and few of those */
static void
compare(const char *what, const uint8_t *a, const uint8_t *b, size_t n)
{
	size_t off = 0, worst = 0;

	for (size_t i = 0; i < n; i++) {
		size_t d = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i];

		off += d != 0;
		worst = d > worst ? d : worst;
	}
	printf("%s: %zu of %zu values differ, by %zu at most\n", what, off, n, worst);
	CHECK(worst <= 1 && off * 20 < n, "%s: the integer picture is not the float one's", what);
}

static void
test_integer_pictures(void)
{
	struct sim s;
	struct isp isp;
	uint32_t w = 640, h = 480, pw = 400, ph = 300;
	uint8_t *y[2], *uv[2], *bgra[2], *fy[2], *fuv[2];
	unsigned seed = 1;

	sim_init(&s, w, h, 0.05);
	sim_frame(&s);
	/* noise, so that every site's own value matters */
	for (uint32_t i = 0; i < s.f.stride * h; i++) {
		seed = seed * 1103515245 + 12345;
		s.raw[i] ^= (uint8_t)((seed >> 16) & 7);
	}
	isp_init(&isp);
	isp.wb[0] = 1.9f;
	isp.wb[2] = 1.4f;
	isp.digital = 1.3f;
	isp_set_ccm(&isp, (const float[9]){ 1.6f, -0.4f, -0.2f, -0.3f, 1.5f, -0.2f, 0.05f, -0.6f, 1.55f });
	isp.lsc.on = true;
	for (int c = 0; c < 3; c++) {
		for (int gy = 0; gy < LSC_H; gy++) {
			for (int gx = 0; gx < LSC_W; gx++) {
				float dx = (gx - 8) / 8.0f, dy = (gy - 6) / 6.0f;

				isp.lsc.gain[c][gy][gx] = 1 + (0.8f + 0.2f * c) * (dx * dx + dy * dy);
			}
		}
	}
	for (int k = 0; k < 2; k++) {
		y[k] = calloc(pw, ph);
		uv[k] = calloc(pw, ph / 2);
		bgra[k] = calloc(4 * pw, ph);
		fy[k] = calloc(w, h);
		fuv[k] = calloc(w, h / 2);
		isp.reference = k == 1;
		isp_render_nv12(&isp, &s.f, s.raw, y[k], pw, uv[k], pw, pw, ph, 0, ph, false);
		isp_render_bgra(&isp, &s.f, s.raw, bgra[k], 4 * pw, pw, ph, 0, ph);
		isp_render_full_nv12(&isp, &s.f, s.raw, fy[k], w, fuv[k], w, 0, h, true);
	}
	compare("preview Y", y[0], y[1], (size_t)pw * ph);
	compare("preview CbCr", uv[0], uv[1], (size_t)pw * ph / 2);
	compare("preview BGRA", bgra[0], bgra[1], (size_t)4 * pw * ph);
	compare("full Y", fy[0], fy[1], (size_t)w * h);
	compare("full CbCr", fuv[0], fuv[1], (size_t)w * h / 2);
}

/* isp_hosttest tuning FILE LUX CCT: the file as isp_load_tuning() reads it, and what isp_tune() makes of it there */
static int
show_tuning(const char *path, float lux, float cct)
{
	struct isp isp;

	isp_init(&isp);
	if (!isp_load_tuning(&isp, path)) {
		printf("not a tuning file\n");
		return 1;
	}
	isp_tune(&isp, lux, cct);
	printf("lights %u %u refs %u\n", isp.tuning->ccm.lights, isp.tuning->lsc.lights, isp.tuning->refs);
	printf("ccm %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f\n", isp.ccm[0][0], isp.ccm[0][1], isp.ccm[0][2], isp.ccm[1][0],
	    isp.ccm[1][1], isp.ccm[1][2], isp.ccm[2][0], isp.ccm[2][1], isp.ccm[2][2]);
	printf("lsc %.4f %.4f %.4f %.4f\n", isp.lsc.gain[0][6][8], isp.lsc.gain[0][0][0], isp.lsc.gain[1][0][0], isp.lsc.gain[2][12][16]);
	isp.wb[0] = 1 / isp.tuning->ref[0][0];
	isp.wb[2] = 1 / isp.tuning->ref[0][1];
	printf("cct %.0f\n", isp_cct(&isp));
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc == 5 && strcmp(argv[1], "tuning") == 0) {
		return show_tuning(argv[2], (float)atof(argv[3]), (float)atof(argv[4]));
	}
	test_integer_pictures();
	test_ae_dark_does_not_freeze();
	test_ae_bright();
	test_ae_controls();
	test_ae_sensor_digital();
	test_awb_lock();
	printf("%s (%d failures)\n", failures ? "FAILED" : "ok", failures);
	return failures != 0;
}
