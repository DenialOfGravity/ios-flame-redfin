/*
 * bluetool: a stand-in for /usr/sbin/BlueTool on redfin (WCN3998, not a Broadcom chip).
 *
 * bluetoothd asks BlueTool (launchd job com.apple.BlueTool, "BlueTool -R", Mach service com.apple.BlueTool)
 * over XPC to boot and initialise the controller before it opens the HCI transport. The real BlueTool picks
 * Broadcom patchram scripts from MobileGestalt WifiVendor + the Broadcom Wi-Fi bus driver's chip id; on
 * redfin it finds neither ("failed to fetch wifi vendor", "Manufacturer is -1", NO_FW_FOUND, result 13 every
 * 5 s) and bluetoothd never gets past "waiting for BlueTool". Here btd (phone/bt, --bridge) already powered
 * the controller, loaded its firmware and set its address, so every request is answered "done".
 *
 * Request/reply shape (from ios-asteroids' docs/BT_IOS_TRANSPORT.md, iOS 16.7 disassembly; not observed on
 * redfin yet): a dictionary with kMsgId (RunBuiltinScript / RunExternalScript / RunCommand) and kMsgArgs
 * { script = boot | init | deepsleep, btaddress }, reply keys result (0 = ok), firmware, output,
 * manufacturer, btaddress. This program does not depend on the shape: whatever arrives is logged in full and
 * answered with result 0 and the optional keys, so the first boot shows what bluetoothd really sends.
 *
 *   bluetool -R        serve (what the launchd job runs); also with no arguments
 *   bluetool -h        this text
 *
 * Install (tools-claude/bt-launchd.py --bluetool): /var/local/bin/bluetool, and the com.apple.BlueTool job's
 * program pointed at it (the stock binary stays untouched). Log: /private/var/tmp/bluetool-redfin.log
 * (the job runs as mobile). /var/local/bluetool.result (a number) answers that result instead of 0, to test
 * bluetoothd's failure path.
 */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define SERVICE		"com.apple.BlueTool"
#define LOG_PATH	"/private/var/tmp/bluetool-redfin.log"
#define RESULT_PATH	"/var/local/bluetool.result"
#define BTD_READY	"/private/var/tmp/btd-bridge.pid"	/* btd --bridge writes its pid there once the chip is up */
#define BTD_WAIT_S	20

static FILE *log_file;
static unsigned requests;

static void say(const char *fmt, ...)
{
	va_list ap;
	struct timeval tv;

	if (!log_file && (log_file = fopen(LOG_PATH, "a")))
		setvbuf(log_file, NULL, _IOLBF, 0);
	if (!log_file)
		return;
	gettimeofday(&tv, NULL);
	fprintf(log_file, "%ld.%03d [%d] ", (long)tv.tv_sec, (int)(tv.tv_usec / 1000), (int)getpid());
	va_start(ap, fmt);
	vfprintf(log_file, fmt, ap);
	va_end(ap);
	fputc('\n', log_file);
}

static void say_object(const char *what, xpc_object_t o)
{
	char *d = xpc_copy_description(o);
	say("%s %s", what, d ? d : "(no description)");
	free(d);
}

static int64_t result_to_give(void)
{
	FILE *f = fopen(RESULT_PATH, "r");
	long long v = 0;
	if (f) {
		if (fscanf(f, "%lld", &v) != 1)
			v = 0;
		fclose(f);
	}
	return v;
}

/* btd --bridge running (its pid file names a live process; it runs as root, so EPERM counts as alive) */
static int btd_ready(void)
{
	FILE *f = fopen(BTD_READY, "r");
	int pid = 0;
	if (!f)
		return 0;
	if (fscanf(f, "%d", &pid) != 1)
		pid = 0;
	fclose(f);
	return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

/* a string from the request (top level or inside kMsgArgs), for the log line */
static const char *field(xpc_object_t msg, const char *key)
{
	const char *s = xpc_dictionary_get_string(msg, key);
	xpc_object_t args = xpc_dictionary_get_value(msg, "kMsgArgs");
	if (!s && args && xpc_get_type(args) == XPC_TYPE_DICTIONARY)
		s = xpc_dictionary_get_string(args, key);
	return s ? s : "-";
}

static void answer(xpc_connection_t peer, xpc_object_t msg)
{
	xpc_object_t reply, addr, args;
	int64_t result = result_to_give();

	requests++;
	say_object("request:", msg);
	/* "boot": the controller must be btd's before bluetoothd opens the transport (up to BTD_WAIT_S) */
	if (!strcmp(field(msg, "script"), "boot") || requests == 1) {
		int waited = 0;
		while (!btd_ready() && waited < BTD_WAIT_S * 4) {
			usleep(250000);
			waited++;
		}
		say("btd %s after %d ms", btd_ready() ? "ready" : "NOT ready (answering anyway)", waited * 250);
	}
	reply = xpc_dictionary_create_reply(msg);
	if (!reply) {
		say("(no reply wanted) id %s script %s", field(msg, "kMsgId"), field(msg, "script"));
		return;
	}
	xpc_dictionary_set_int64(reply, "result", result);
	xpc_dictionary_set_string(reply, "output", "");
	xpc_dictionary_set_string(reply, "firmware", "qca/crbtfw32.tlv");
	xpc_dictionary_set_string(reply, "manufacturer", "Qualcomm");
	addr = xpc_dictionary_get_value(msg, "btaddress");
	args = xpc_dictionary_get_value(msg, "kMsgArgs");
	if (!addr && args && xpc_get_type(args) == XPC_TYPE_DICTIONARY)
		addr = xpc_dictionary_get_value(args, "btaddress");
	if (addr)
		xpc_dictionary_set_value(reply, "btaddress", addr);
	say("answer %u: id %s script %s -> result %lld", requests, field(msg, "kMsgId"), field(msg, "script"),
	    (long long)result);
	xpc_connection_send_message(peer, reply);
	xpc_release(reply);
}

int main(int argc, char **argv)
{
	typedef xpc_connection_t (*listen_fn)(const char *, dispatch_queue_t, uint64_t);
	int serve = argc == 1;
	listen_fn listen;
	xpc_connection_t listener;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-R"))
			serve = 1;
		else if (!strcmp(argv[i], "-h")) {
			fprintf(stderr, "bluetool -R: answers bluetoothd's BlueTool requests with result 0 (redfin, btd owns the chip)\n");
			return 0;
		}
	}
	if (!serve) {
		/* someone ran "BlueTool -c ..." by hand: nothing to do, the controller is btd's */
		fprintf(stderr, "bluetool: redfin stand-in, the controller belongs to btd; only -R serves\n");
		return 0;
	}
	/* the iOS SDK hides xpc_connection_create_mach_service; libxpc exports it (the real BlueTool calls it) */
	listen = (listen_fn)dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
	if (!listen) {
		say("xpc_connection_create_mach_service missing");
		return 1;
	}
	listener = listen(SERVICE, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
	if (!listener) {
		say("cannot listen on " SERVICE);
		return 1;
	}
	say("serving " SERVICE " (result %lld)", (long long)result_to_give());
	xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
			say_object("listener event:", peer);
			return;
		}
		/* (xpc_connection_get_pid is hidden by the iOS SDK too; libxpc exports it) */
		pid_t (*get_pid)(xpc_connection_t) = (pid_t (*)(xpc_connection_t))dlsym(RTLD_DEFAULT, "xpc_connection_get_pid");
		pid_t pid = get_pid ? get_pid((xpc_connection_t)peer) : -1;
		say("connection from pid %d", (int)pid);
		xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t msg) {
			if (xpc_get_type(msg) == XPC_TYPE_DICTIONARY)
				answer((xpc_connection_t)peer, msg);
			else if (msg == XPC_ERROR_CONNECTION_INVALID)
				say("pid %d went away", (int)pid);
			else
				say_object("event:", msg);
		});
		xpc_connection_resume((xpc_connection_t)peer);
	});
	xpc_connection_resume(listener);
	dispatch_main();
}
