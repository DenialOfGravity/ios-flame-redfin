/* fastrpcd: log lines (stderr only: syslog() cost milliseconds per line while the DSP waited). Copyright (C) 2026 the ios-flame contributors. GPL-3.0-or-later. */
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include "log.h"

int flog_verbose;

void flog(const char *fmt, ...)
{
	char line[1024];
	struct timeval tv;
	struct tm tm;
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	gettimeofday(&tv, NULL);
	localtime_r(&tv.tv_sec, &tm);
	fprintf(stderr, "%02d:%02d:%02d.%03d fastrpcd: %s\n", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000), line);
	fflush(stderr);
}
