/*
 * membw: CPU memory bandwidth (reads and copies of buffers far larger than the caches), to see where the DDR
 * clock sits (RPMh BCM MC0/SH0 votes).
 *   membw [THREADS] [MB]     default 8 threads, 32 MB each; best of 6 rounds, all threads at once
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

static size_t n;
static volatile uint64_t sink;

static double now_s(void)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom)
		mach_timebase_info(&tb);
	return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

struct job { uint64_t *a, *b; double rd, cp; };

static void *worker(void *arg)
{
	struct job *j = arg;
	for (int r = 0; r < 6; r++) {
		double t0 = now_s();
		uint64_t s = 0;
		for (size_t i = 0; i < n / 8; i += 8)
			s += j->a[i] + j->a[i + 1] + j->a[i + 2] + j->a[i + 3] + j->a[i + 4] + j->a[i + 5] + j->a[i + 6] + j->a[i + 7];
		double t1 = now_s();
		memcpy(j->b, j->a, n);
		__asm__ volatile("" ::: "memory");
		double t2 = now_s();
		sink += s + j->b[r];
		if (r && (double)n / (t1 - t0) > j->rd)
			j->rd = (double)n / (t1 - t0);
		if (r && 2.0 * n / (t2 - t1) > j->cp)
			j->cp = 2.0 * n / (t2 - t1);
	}
	return NULL;
}

int main(int argc, char **argv)
{
	int threads = argc > 1 ? atoi(argv[1]) : 8;
	n = (size_t)(argc > 2 ? atoi(argv[2]) : 32) << 20;
	pthread_t t[64];
	struct job j[64];
	for (int i = 0; i < threads; i++) {
		j[i].a = malloc(n);
		j[i].b = malloc(n);
		memset(j[i].a, i + 1, n);
		memset(j[i].b, 0, n);
		j[i].rd = j[i].cp = 0;
	}
	double t0 = now_s();
	for (int i = 0; i < threads; i++)
		pthread_create(&t[i], NULL, worker, &j[i]);
	double rd = 0, cp = 0;
	for (int i = 0; i < threads; i++) {
		pthread_join(t[i], NULL);
		rd += j[i].rd;
		cp += j[i].cp;
	}
	double total = 6.0 * threads * 3.0 * n / (now_s() - t0) / 1e9;
	printf("membw: %d threads x %zu MB: read %.2f GB/s, memcpy %.2f GB/s (sum of per-thread bests), overall %.2f GB/s\n",
	       threads, n >> 20, rd / 1e9, cp / 1e9, total);
	return 0;
}
