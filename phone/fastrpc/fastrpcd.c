/*
 * fastrpcd: the file service of the ADSP's sensors protection domain, for iOS on the Pixel 5 (redfin).
 *
 * The same job as Android's adsprpcd / postmarketOS's hexagonrpcd (whose listener, localctl, apps_mem and
 * marshalling code this is built from, see LICENSE.hexagonrpc): attach to the sensors PD over the kernel's
 * /dev/redwood-fastrpc (XNU patch 0950), register as its default listener and serve its apps_std calls
 * (fopen/fread/stat/readdir of the sensor configuration and registry) from a directory tree on the phone.
 * Without it the sensors PD dies ~10 s after the DSP boots (sar.cc chre_utils fatal) and takes the DSP down.
 *
 *   fastrpcd [-v] [-r ROOT] [--mmap-method 2|4] [-d DEVICE]
 *     -v               log every call (otherwise: opens, stats, listings, writes, errors)
 *     -r ROOT          served tree (default /private/var/local/hexagon)
 *     --mmap-method N  INIT_MMAP as Android 64-bit (2) or Linux (4, default); the other is tried if it fails
 *     -d DEVICE        default /dev/redwood-fastrpc
 * Exit: 0 off (/var/local/fastrpcd.off), 1 error, 2 usage / no tree, 3 the DSP has gone (ECONNRESET: launchd
 * starts us again for the DSP that comes back), 4 the DSP refused the attach or the listener.
 *
 * Copyright (C) 2026 the ios-flame contributors. GPL-3.0-or-later.
 */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#include <libhexagonrpc/error.h>
#include <libhexagonrpc/handle.h>
#include <libhexagonrpc/hexagonrpc.h>
#include "apps_mem.h"
#include "apps_std.h"
#include "interface/adsp_default_listener.h"
#include "listener.h"
#include "localctl.h"
#include "log.h"
#include "transport.h"

#define EXIT_OFF	0
#define EXIT_ERROR	1
#define EXIT_USAGE	2
#define EXIT_DSP_GONE	3
#define EXIT_REFUSED	4

#define OFF_FILE	"/var/local/fastrpcd.off"

static void usage(void)
{
	fprintf(stderr, "usage: fastrpcd [-v] [-r ROOT] [--mmap-method 2|4] [-d DEVICE]\n");
	exit(EXIT_USAGE);
}

static void backoff(unsigned *s)
{
	sleep(*s);
	*s = *s * 2 > 30 ? 30 : *s * 2;
}

static int off(void)
{
	struct stat st;

	return stat(OFF_FILE, &st) == 0;
}

static int register_listener(int fd)
{
	uint32_t hdl;
	char err[256] = "";
	int ret;

	ret = hexagonrpc_open(fd, "adsp_default_listener", &hdl, sizeof(err), err);
	if (ret) {
		flog("remotectl open adsp_default_listener: %s", err[0] ? err : "failed");
		return -1;
	}
	ret = adsp_default_listener_register(fd, hdl);
	flog("adsp_default_listener (handle %#x) register -> %d%s%s", hdl, ret, ret ? ": " : "",
	     ret ? hexagonrpc_strerror(ret) : "");
	hexagonrpc_close(fd, hdl);
	return ret;
}

int main(int argc, char **argv)
{
	const char *root = "/private/var/local/hexagon", *device = "/dev/redwood-fastrpc";
	struct fastrpc_interface *ifaces[3];
	struct frpc_dev dev;
	struct frpc_mem mem;
	struct stat st;
	unsigned wait = 1;
	int i, fd, ret, tries;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-v"))
			flog_verbose = 1;
		else if (!strcmp(argv[i], "-r") && i + 1 < argc)
			root = argv[++i];
		else if (!strcmp(argv[i], "-d") && i + 1 < argc)
			device = argv[++i];
		else if (!strcmp(argv[i], "--mmap-method") && i + 1 < argc) {
			frpc_mmap_method = atoi(argv[++i]);
			if (frpc_mmap_method != 2 && frpc_mmap_method != 4)
				usage();
		} else
			usage();
	}
	signal(SIGPIPE, SIG_IGN);
	flog("starting (pid %d): tree %s, device %s, INIT_MMAP method %d", (int)getpid(), root, device, frpc_mmap_method);
	if (off()) {
		flog("%s exists: not starting", OFF_FILE);
		return EXIT_OFF;
	}
	if (stat(root, &st) || !S_ISDIR(st.st_mode)) {
		flog("served tree %s: missing (tools/redfin-install-hexagon-wsl.sh installs it)", root);
		sleep(30);	/* launchd would start us again at once */
		return EXIT_USAGE;
	}

	/* The device: absent until the kernel has it, busy while another fastrpcd runs. */
	while (frpc_open_device(device, &dev, &mem)) {
		if (errno != ENOENT && errno != EBUSY && errno != ENXIO)
			return EXIT_ERROR;
		if (off())
			return EXIT_OFF;
		backoff(&wait);
	}
	if (frpc_start(&dev, &mem)) {
		flog("answer reader: %s", strerror(errno));
		return EXIT_ERROR;
	}
	fd = frpc_session_new((int32_t)getpid());

	/* Attach to the sensors PD; ENOTCONN: the DSP has not opened the channel yet. */
	wait = 1;
	for (tries = 0;; tries++) {
		ret = fastrpc_ioctl(fd, FASTRPC_IOCTL_INIT_ATTACH_SNS, NULL);
		if (ret == 0)
			break;
		if (frpc_dead())
			return EXIT_DSP_GONE;
		if (ret == -1 && errno != ENOTCONN && errno != EAGAIN)
			return EXIT_ERROR;
		if (ret > 0 && tries >= 5) {
			flog("the DSP refused INIT_ATTACH_SNS %d times (last %d, %s): giving up", tries + 1, ret,
			     hexagonrpc_strerror(ret));
			return EXIT_REFUSED;
		}
		if (off())
			return EXIT_OFF;
		backoff(&wait);
	}

	ifaces[0] = fastrpc_localctl_init(3, ifaces);
	ifaces[1] = fastrpc_apps_std_init(root);
	ifaces[2] = fastrpc_apps_mem_init(fd);
	if (!ifaces[0] || !ifaces[1] || !ifaces[2]) {
		flog("interfaces: out of memory or no tree");
		return EXIT_ERROR;
	}
	if (register_listener(fd)) {
		frpc_stop();
		return frpc_dead() ? EXIT_DSP_GONE : EXIT_REFUSED;
	}
	ret = run_fastrpc_listener(fd, 3, ifaces);
	if (frpc_dead()) {
		flog("the DSP has gone (listener ended with %d): exiting for launchd to start us again", ret);
		return EXIT_DSP_GONE;
	}
	flog("listener ended: %d (%s)", ret, hexagonrpc_strerror(ret));
	return ret > 0 ? EXIT_REFUSED : EXIT_ERROR;
}
