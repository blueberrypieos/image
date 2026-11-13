/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 The Blueberry Pie OS Authors
 *
 * usage: deadman TIMEOUT STALE FILE
 *
 * Checks in with the kernel's watchdog every 5 seconds, with TIMEOUT
 * seconds to the next check-in, while FILE keeps changing: each change of
 * its modification time counts as a heartbeat. Once STALE seconds pass
 * without one, it stops checking in, and the kernel panics TIMEOUT seconds
 * later. FILE must be fresh when it starts. The time between heartbeats is
 * measured on the monotonic clock. A failed check-in leaves the last one
 * in force and exits 1. SIGUSR1 ends the check-ins and exits 0; if
 * ending them fails, the last check-in stays in force and it exits 1.
 * SIGTERM or SIGINT exits 2 and leaves the last check-in in force, so a
 * shutdown that kills it and then hangs still ends in a panic. The
 * watchdog driver itself ends the check-ins once a shutdown is under way.
 * SIGHUP is ignored.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t done;

static void
stop(int sig)
{
	done = sig;
}

static int
check_in(io_service_t wd, int seconds)
{
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &seconds);
	kern_return_t kr = IORegistryEntrySetCFProperties(wd, n);
	CFRelease(n);
	return kr == KERN_SUCCESS ? 0 : -1;
}

static double
now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

int
main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "usage: deadman TIMEOUT STALE FILE\n");
		return 2;
	}
	int timeout = atoi(argv[1]), stale = atoi(argv[2]);
	const char *file = argv[3];
	if (timeout < 30 || stale < 30) {
		fprintf(stderr, "deadman: TIMEOUT and STALE must be 30 s or more\n");
		return 2;
	}
	struct stat st;
	time_t wall = time(NULL);
	if (stat(file, &st) != 0 || st.st_mtime > wall + 60 || wall - st.st_mtime >= stale) {
		fprintf(stderr, "deadman: %s must exist and be fresh\n", file);
		return 2;
	}
	io_service_t wd = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOWatchDogTimer"));
	if (!wd) {
		fprintf(stderr, "deadman: no IOWatchDogTimer service\n");
		return 1;
	}
	signal(SIGTERM, stop);
	signal(SIGINT, stop);
	signal(SIGUSR1, stop);
	signal(SIGHUP, SIG_IGN);
	struct timespec last = st.st_mtimespec;
	double beat = now();
	int checking = 0, failed = 0;
	while (!done) {
		if (stat(file, &st) == 0 &&
		    (st.st_mtimespec.tv_sec != last.tv_sec || st.st_mtimespec.tv_nsec != last.tv_nsec)) {
			last = st.st_mtimespec;
			beat = now();
		}
		if (now() - beat < stale) {
			if (check_in(wd, timeout) != 0) {
				fprintf(stderr, "deadman: a check-in failed; the last one stays in force\n");
				failed = 1;
				break;
			}
			if (!checking) {
				printf("deadman: checking in every 5 s, %d s allowed\n", timeout);
				fflush(stdout);
			}
			checking = 1;
		} else if (checking) {
			printf("deadman: no heartbeat for %d s: no more check-ins\n", stale);
			fflush(stdout);
			checking = 0;
		}
		sleep(5);
	}
	if (failed) {
		return 1;
	}
	if (done != SIGUSR1) {
		printf("deadman: stopped; the last check-in stays in force\n");
		return 2;
	}
	if (check_in(wd, 0) != 0) {
		fprintf(stderr, "deadman: ending the check-ins failed; the last one stays in force\n");
		return 1;
	}
	printf("deadman: check-ins ended\n");
	IOObjectRelease(wd);
	return 0;
}
