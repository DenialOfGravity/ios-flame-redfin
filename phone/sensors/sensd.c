/*
 * sensd: the phone's sensors (LSM6DSR accel+gyro, TCS3701 ambient light+proximity, LIS2MDL compass, BMP380
 * pressure) from the ADSP's sensors PD (Qualcomm SEE) into iOS. QMI service 400 over QRTR through
 * /dev/redwood-qrtr (kernel 0956); samples go to /dev/redwood-motion (kernel 0972), which posts them from
 * the SweetHID* sensor services backboardd/locationd read.
 *
 *   sensd --list                 kernel service list, then each sensor's SUID and attributes
 *   sensd --stream NAME [HZ]     one sensor, every sample printed (NAME: accel gyro als prox compass pressure,
 *                                or the SEE data type: ambient_light proximity mag)
 *   sensd --all                  every sensor the DSP has, one summary line per sensor per second
 *   sensd --daemon               the boot job (launchd org.iosonpixel.sensd): waits for the DSP, streams what
 *                                iOS asks for (ReportInterval via MOTION_GET_WANT), recovers from DSP restarts;
 *                                off with /var/local/sensd.off
 * Options: --dump (every QMI message in hex), --secs N (stop after N s), --no-motion (print only),
 *          --no-orient (no type-10 orientation samples from accel), --no-follow (daemon: stream everything),
 *          --node N --port P (skip the service lookup), --qrtr-fd FD (an inherited fd instead of the device),
 *          --orient-inject [TYPE] (hand each orientation sensd derives to backboardd, below).
 *   sensd --orient-set N [TYPE]  set the device orientation once and hold it for --secs (default 30) s
 *
 * Orientation injection: on iPhones backboardd's BKOrientationManager takes the device orientation from CoreMotion
 * (locationd), which has no motion input here. BackBoardServices' BKSHIDServicesLockOrientation(orientation,
 * TYPE) locks backboardd's effective device orientation instead (BKSHIDServicesUnlockOrientation first: a second
 * lock is ignored while one is held). TYPE is the lock type (unknown enum, default 0); TYPE -1 uses
 * BKSHIDServicesSetDeviceInterfaceOrientation(orientation) instead. Needs sensd-ents.plist's entitlements.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include "rqrtr.h"
#include "sensor.h"

static struct {
	int motion_fd;
	int print;		/* 0 none, 1 every sample, 2 summary */
	int verbose, orient, follow, secs;
	uint32_t node, port;
	int qrtr_fd;
	uint64_t written, write_errors;
	int inject, inject_type;
} opt = { .motion_fd = -1, .orient = 1, .follow = 1, .qrtr_fd = -1 };

static volatile sig_atomic_t stop_flag;
static void on_signal(int sig) { (void)sig; stop_flag = 1; }

static void stamp(void)
{
	time_t t = time(NULL);
	struct tm tm;
	localtime_r(&t, &tm);
	printf("%02d:%02d:%02d ", tm.tm_hour, tm.tm_min, tm.tm_sec);
}

/* BackBoardServices, looked up at run time (no SDK stubs for it). */
static void (*bks_lock)(long orientation, long type);
static void (*bks_unlock)(void);
static void (*bks_set_interface)(long orientation);

static int bks_load(void)
{
	void *h = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
	if (!h) {
		printf("sensd: BackBoardServices: %s\n", dlerror());
		return -1;
	}
	bks_lock = (void (*)(long, long))dlsym(h, "BKSHIDServicesLockOrientation");
	bks_unlock = (void (*)(void))dlsym(h, "BKSHIDServicesUnlockOrientation");
	bks_set_interface = (void (*)(long))dlsym(h, "BKSHIDServicesSetDeviceInterfaceOrientation");
	printf("sensd: BKSHIDServicesLockOrientation %p, Unlock %p, SetDeviceInterfaceOrientation %p\n",
	    (void *)bks_lock, (void *)bks_unlock, (void *)bks_set_interface);
	return bks_lock && bks_unlock ? 0 : -1;
}

static void bks_orient(int o, int type)
{
	if (type < 0) {
		if (bks_set_interface)
			bks_set_interface(o);
	} else if (bks_lock && bks_unlock) {
		bks_unlock();
		bks_lock(o, type);
	}
	stamp();
	printf("sensd: orientation %d -> backboardd (%s %d)\n", o, type < 0 ? "SetDeviceInterfaceOrientation" :
	    "LockOrientation type", type);
	fflush(stdout);
}

static void out(void *ctx, struct sensor *s, const struct motion_sample *m)
{
	if (opt.inject && m->type == MOTION_TYPE_ORIENTATION)
		bks_orient((int)m->v[0], opt.inject_type);
	(void)ctx;
	if (opt.motion_fd >= 0) {
		if (write(opt.motion_fd, m, sizeof(*m)) == (ssize_t)sizeof(*m))
			opt.written++;
		else if (opt.write_errors++ < 5)
			perror("sensd: /dev/redwood-motion write");
	}
	if (opt.print == 1) {
		if (m->type == MOTION_TYPE_ORIENTATION)
			printf("orientation %.0f\n", m->v[0]);
		else
			printf("%-8s %14llu %10.4f %10.4f %10.4f  [%u]\n", s->k->alias, (unsigned long long)m->ts_mach,
			    m->v[0], m->v[1], m->v[2], m->flags & MOTION_FLAG_ACCURACY);
		fflush(stdout);
	} else if (opt.print == 2 && m->type == MOTION_TYPE_ORIENTATION) {
		printf("orientation %.0f\n", m->v[0]);
	}
}

static struct sensor_env env = { .out = out };

static int open_port(void)
{
	if (opt.qrtr_fd >= 0) {
		fcntl(opt.qrtr_fd, F_SETFL, O_NONBLOCK);
		return dup(opt.qrtr_fd);
	}
	return rqrtr_open();
}

/* The SNS service's node/port, or -1. */
static int find_service(int fd, uint32_t *node, uint32_t *port, int quiet)
{
	if (opt.node || opt.port) {
		*node = opt.node;
		*port = opt.port;
		return 0;
	}
	if (rqrtr_lookup(fd, SNS_QMI_SERVICE, node, port)) {
		if (!quiet)
			printf("sensd: QMI service %u (SNS) is not up%s\n", SNS_QMI_SERVICE,
			    errno == ENOTTY ? " (no QRTR_LOOKUP ioctl: kernel without 0956?)" : "");
		return -1;
	}
	return 0;
}

static void open_motion(void)
{
	if (opt.motion_fd >= 0)
		return;
	opt.motion_fd = open(MOTION_DEV, O_RDWR | O_NONBLOCK);
	if (opt.motion_fd < 0)
		printf("sensd: %s: %s (printing only)\n", MOTION_DEV, strerror(errno));
}

static void print_motion_status(void)
{
	char buf[2048];
	int fd = open(MOTION_DEV, O_RDONLY);
	if (fd < 0)
		return;
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n > 0) {
		buf[n] = 0;
		printf("%s:\n%s", MOTION_DEV, buf);
	}
}

static int cmd_list(void)
{
	const char *svcs = rqrtr_services();
	uint32_t node, port;
	int fd = open_port(), found = 0;

	printf("kern.sweet_adsp_services: %s\n", svcs ? svcs : "(none: kernel without 0956?)");
	if (fd < 0) {
		printf("sensd: %s: %s\n", RQRTR_DEV, strerror(errno));
		return 1;
	}
	if (find_service(fd, &node, &port, 0))
		return 1;
	printf("SNS service %u at node %u port %u\n", SNS_QMI_SERVICE, node, port);
	for (int i = 0; i < sensor_nkinds; i++) {
		struct sensor s;
		sensor_init(&s, &sensor_kinds[i], fd, node, port);
		if (sensor_lookup(&env, &s))
			continue;
		found++;
		if (sensor_get_attrs(&env, &s))
			printf("sensd: %s: no attributes\n", s.k->alias);
		sensor_print_attrs(&s);
	}
	close(fd);
	print_motion_status();
	return found ? 0 : 1;
}

static int setup(struct sensor *s, const struct sensor_kind *k, int quiet)
{
	uint32_t node, port;
	int fd = open_port();
	memset(s, 0, sizeof(*s));
	s->fd = -1;
	if (fd < 0) {
		printf("sensd: %s: %s\n", RQRTR_DEV, strerror(errno));
		return -1;
	}
	if (find_service(fd, &node, &port, quiet)) {
		close(fd);
		return -1;
	}
	sensor_init(s, k, fd, node, port);
	if (sensor_lookup(&env, s)) {
		close(fd);
		s->fd = -1;
		return -1;
	}
	if (sensor_get_attrs(&env, s) == 0)
		sensor_print_attrs(s);
	return 0;
}

static void summary(struct sensor *ss, int n)
{
	stamp();
	for (int i = 0; i < n; i++) {
		struct sensor *s = &ss[i];
		if (s->fd < 0)
			continue;
		printf("%s %llu/s", s->k->alias, (unsigned long long)(s->count - s->count_at_print));
		for (int j = 0; j < s->nv && j < 3; j++)
			printf(" %.3f", s->v[j]);
		printf(" | ");
		s->count_at_print = s->count;
	}
	printf("motion %llu\n", (unsigned long long)opt.written);
	fflush(stdout);
}

/* Poll every open sensor until --secs passes or a signal; returns 0, or -1 when a port failed. */
static int run(struct sensor *ss, int n, int daemon)
{
	long t0 = sensor_now_ms(), last_print = t0, last_want = 0;
	for (;;) {
		long now = sensor_now_ms();
		int handled = 0;
		if (stop_flag || (opt.secs && now - t0 >= opt.secs * 1000L))
			return 0;
		for (int i = 0; i < n; i++) {
			if (ss[i].fd < 0)
				continue;
			int h = sensor_poll(&env, &ss[i], 0);
			if (h < 0)
				return -1;
			handled += h;
			if (daemon && ss[i].active && now - ss[i].last_data_ms > 15000 && ss[i].hz > 0) {
				stamp();
				printf("sensd: %s: no data for 15 s: starting over\n", ss[i].k->alias);
				return -1;
			}
		}
		if (opt.print == 2 && now - last_print >= 1000) {
			summary(ss, n);
			last_print = now;
		}
		if (daemon && now - last_print >= 60000) {
			summary(ss, n);
			last_print = now;
		}
		if (daemon && now - last_want >= 2000) {
			last_want = now;
			struct motion_want w;
			int have = opt.follow && opt.motion_fd >= 0 && ioctl(opt.motion_fd, MOTION_GET_WANT, &w) == 0;
			for (int i = 0; i < n; i++) {
				struct sensor *s = &ss[i];
				if (s->fd < 0)
					continue;
				int idx = s->k->motion_index;
				float hz = s->k->default_hz;
				int on = 1;
				if (have && w.interval_set[idx]) {
					on = w.interval_us[idx] != 0;
					if (on && !s->k->on_change) {
						hz = 1e6f / (float)w.interval_us[idx];
						hz = hz < 1 ? 1 : (hz > 200 ? 200 : hz);
					}
				}
				if (on && (!s->active || (!s->k->on_change && (s->hz < hz * 0.9f || s->hz > hz * 1.1f)))) {
					stamp();
					printf("sensd: %s: start%s %.1f Hz\n", s->k->alias, s->active ? " (new rate)" : "",
					    s->k->on_change ? 0.0 : hz);
					if (sensor_start(&env, s, hz))
						return -1;
				} else if (!on && s->active) {
					stamp();
					printf("sensd: %s: stop (iOS set ReportInterval 0)\n", s->k->alias);
					if (sensor_stop(&env, s))
						return -1;
				}
			}
		}
		if (!handled) {
			struct timespec ts = { 0, 5000000 };
			nanosleep(&ts, NULL);
		}
	}
}

static void close_all(struct sensor *ss, int n)
{
	for (int i = 0; i < n; i++) {
		if (ss[i].fd >= 0) {
			sensor_stop(&env, &ss[i]);
			close(ss[i].fd);
			ss[i].fd = -1;
		}
	}
}

static int cmd_stream(const char *name, float hz)
{
	const struct sensor_kind *k = sensor_kind_find(name);
	struct sensor s;
	if (!k) {
		printf("sensd: unknown sensor \"%s\"\n", name);
		return 2;
	}
	if (setup(&s, k, 0))
		return 1;
	if (sensor_start(&env, &s, hz))
		return 1;
	printf("sensd: %s streaming%s\n", k->alias, k->on_change ? " (on change)" : "");
	int rc = run(&s, 1, 0);
	close_all(&s, 1);
	printf("sensd: %llu samples, %llu written to %s\n", (unsigned long long)s.count,
	    (unsigned long long)opt.written, MOTION_DEV);
	return rc ? 1 : 0;
}

static int cmd_all(void)
{
	struct sensor ss[8];
	int n = 0;
	for (int i = 0; i < sensor_nkinds; i++) {
		if (setup(&ss[n], &sensor_kinds[i], 0) == 0 && sensor_start(&env, &ss[n], 0) == 0)
			n++;
		else if (ss[n].fd >= 0) {
			close(ss[n].fd);
		}
	}
	if (!n)
		return 1;
	int rc = run(ss, n, 0);
	close_all(ss, n);
	return rc ? 1 : 0;
}

static int cmd_daemon(void)
{
	struct sensor ss[8];
	long last_complaint = -100000;
	opt.print = 0;
	stamp();
	printf("sensd: daemon start (follow %d, orient %d)\n", opt.follow, opt.orient);
	fflush(stdout);
	while (!stop_flag) {
		struct stat st;
		if (stat("/var/local/sensd.off", &st) == 0) {
			printf("sensd: /var/local/sensd.off: exiting\n");
			return 0;
		}
		int fd = open_port();
		uint32_t node, port;
		int quiet = sensor_now_ms() - last_complaint < 60000;
		if (fd < 0 || find_service(fd, &node, &port, quiet)) {
			if (!quiet) {
				stamp();
				printf("sensd: waiting for %s and the SNS service\n", RQRTR_DEV);
				fflush(stdout);
				last_complaint = sensor_now_ms();
			}
			if (fd >= 0)
				close(fd);
			sleep(3);
			continue;
		}
		close(fd);
		open_motion();
		int n = 0;
		for (int i = 0; i < sensor_nkinds; i++) {
			if (setup(&ss[n], &sensor_kinds[i], 1) == 0)
				n++;
		}
		stamp();
		printf("sensd: %d sensors\n", n);
		fflush(stdout);
		if (!n) {
			sleep(30);
			continue;
		}
		run(ss, n, 1);
		close_all(ss, n);
		sleep(2);
	}
	return 0;
}

static void usage(void)
{
	printf("usage: sensd --list | --stream NAME [HZ] | --all | --daemon  [--dump] [--secs N] [--no-motion]\n"
	    "       [--no-orient] [--no-follow] [--orient-inject [TYPE]] [--node N --port P] [--qrtr-fd FD]\n"
	    "       sensd --orient-set N [TYPE] [--secs S]\n"
	    "NAME: accel gyro als prox compass pressure (or ambient_light proximity mag)\n");
}

int main(int argc, char **argv)
{
	const char *mode = NULL, *name = NULL;
	float hz = 0;
	int motion = 1;

	setvbuf(stdout, NULL, _IOLBF, 0);
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "--list") || !strcmp(a, "--all") || !strcmp(a, "--daemon"))
			mode = a + 2;
		else if (!strcmp(a, "--stream") && i + 1 < argc) {
			mode = "stream";
			name = argv[++i];
			if (i + 1 < argc && argv[i + 1][0] != '-')
				hz = (float)atof(argv[++i]);
		} else if (!strcmp(a, "--dump"))
			opt.verbose = 1;
		else if (!strcmp(a, "--secs") && i + 1 < argc)
			opt.secs = atoi(argv[++i]);
		else if (!strcmp(a, "--no-motion"))
			motion = 0;
		else if (!strcmp(a, "--no-orient"))
			opt.orient = 0;
		else if (!strcmp(a, "--orient-inject")) {
			opt.inject = 1;
			if (i + 1 < argc && (argv[i + 1][0] != '-' || (argv[i + 1][1] >= '0' && argv[i + 1][1] <= '9')))
				opt.inject_type = atoi(argv[++i]);
		} else if (!strcmp(a, "--orient-set") && i + 1 < argc) {
			mode = "orient-set";
			hz = (float)atoi(argv[++i]);
			if (i + 1 < argc && (argv[i + 1][0] != '-' || (argv[i + 1][1] >= '0' && argv[i + 1][1] <= '9')))
				opt.inject_type = atoi(argv[++i]);
		} else if (!strcmp(a, "--no-follow"))
			opt.follow = 0;
		else if (!strcmp(a, "--node") && i + 1 < argc)
			opt.node = (uint32_t)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--port") && i + 1 < argc)
			opt.port = (uint32_t)strtoul(argv[++i], NULL, 0);
		else if (!strcmp(a, "--qrtr-fd") && i + 1 < argc)
			opt.qrtr_fd = atoi(argv[++i]);
		else {
			usage();
			return 2;
		}
	}
	if (!mode) {
		usage();
		return 2;
	}
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);
	if (!strcmp(mode, "orient-set")) {
		if (bks_load())
			return 1;
		bks_orient((int)hz, opt.inject_type);
		for (int t = 0; t < (opt.secs ? opt.secs : 30) && !stop_flag; t++)
			sleep(1);
		if (opt.inject_type >= 0 && bks_unlock)
			bks_unlock();
		printf("sensd: orientation released\n");
		return 0;
	}
	if (opt.inject && bks_load())
		opt.inject = 0;
	env.verbose = opt.verbose;
	env.orient = opt.orient;
	if (motion && strcmp(mode, "list"))
		open_motion();
	if (!strcmp(mode, "list"))
		return cmd_list();
	if (!strcmp(mode, "stream")) {
		opt.print = 1;
		return cmd_stream(name, hz);
	}
	if (!strcmp(mode, "all")) {
		opt.print = 2;
		return cmd_all();
	}
	return cmd_daemon();
}
