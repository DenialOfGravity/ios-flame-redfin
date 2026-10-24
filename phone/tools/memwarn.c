/*
 * memwarn: system memory pressure by hand (kern.memorypressure_manual_trigger, development kernels).
 *   memwarn warn | critical | normal
 * Warn/critical make iOS purge caches (CoreAnimation included); normal ends the test level.
 */
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

int main(int argc, char **argv)
{
	int level = -1;
	if (argc == 2 && !strcmp(argv[1], "warn"))
		level = (1 << 16) | 2;		/* NOTE_MEMORYSTATUS_PRESSURE_WARN */
	else if (argc == 2 && !strcmp(argv[1], "critical"))
		level = (1 << 16) | 4;		/* NOTE_MEMORYSTATUS_PRESSURE_CRITICAL */
	else if (argc == 2 && !strcmp(argv[1], "normal"))
		level = 1;			/* off: NOTE_MEMORYSTATUS_PRESSURE_NORMAL, trigger 0 */
	if (level < 0) {
		fprintf(stderr, "usage: memwarn warn|critical|normal\n");
		return 2;
	}
	if (sysctlbyname("kern.memorypressure_manual_trigger", NULL, NULL, &level, sizeof(level))) {
		perror("kern.memorypressure_manual_trigger");
		return 1;
	}
	printf("memory pressure: %s\n", argv[1]);
	return 0;
}
