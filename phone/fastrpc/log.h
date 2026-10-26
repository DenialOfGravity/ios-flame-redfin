/* fastrpcd: log lines to stderr (launchd: /var/local/fastrpcd.log) and syslog. GPL-3.0-or-later. */
#ifndef FASTRPCD_LOG_H
#define FASTRPCD_LOG_H
extern int flog_verbose;
void flog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#define vlog(...) do { if (flog_verbose) flog(__VA_ARGS__); } while (0)
#endif
