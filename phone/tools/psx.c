/*
 * psx: processes on iOS without /proc (toybox ps needs it).
 *   psx              pid ppid uid cpu-seconds name, all processes
 *   psx NAME         just those whose name contains NAME
 *   psx -k NAME [SIG]  kill every process named exactly NAME (default SIGTERM)
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>

int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);	/* libproc; no header in the iOS SDK */

/* user + system CPU time in seconds (rusage times are mach ticks) */
static double cpu_seconds(pid_t pid)
{
	struct rusage_info_v0 ri;
	static mach_timebase_info_data_t tb;
	if (!tb.denom)
		mach_timebase_info(&tb);
	if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&ri))
		return -1;
	return (double)(ri.ri_user_time + ri.ri_system_time) * tb.numer / tb.denom / 1e9;
}

int main(int argc, char **argv)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;
	if (sysctl(mib, 3, NULL, &len, NULL, 0) < 0)
		return perror("sysctl"), 1;
	len += len / 4;
	struct kinfo_proc *p = malloc(len);
	if (sysctl(mib, 3, p, &len, NULL, 0) < 0)
		return perror("sysctl"), 1;
	int n = (int)(len / sizeof(*p)), killed = 0;
	int kill_mode = argc > 2 && !strcmp(argv[1], "-k");
	const char *name = kill_mode ? argv[2] : argc > 1 ? argv[1] : NULL;
	int sig = kill_mode && argc > 3 ? atoi(argv[3]) : SIGTERM;
	for (int i = 0; i < n; i++) {
		const char *c = p[i].kp_proc.p_comm;
		pid_t pid = p[i].kp_proc.p_pid;
		if (kill_mode) {
			if (!strcmp(c, name) && kill(pid, sig) == 0) {
				printf("killed %d %s\n", pid, c);
				killed++;
			}
		} else if (!name || strstr(c, name)) {
			printf("%6d %6d %5u %9.2f %s\n", pid, p[i].kp_eproc.e_ppid, p[i].kp_eproc.e_ucred.cr_uid, cpu_seconds(pid), c);
		}
	}
	return kill_mode && !killed;
}
