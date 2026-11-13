/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 The Blueberry Pie OS Authors
 *
 * usage: install as /usr/appleinternal/sbin/launchd.pieb, and boot a
 * kernel with launchdsuffix=pieb
 *
 * Process 1 for a system under test in /pie-b: mounts the root read-write
 * and a devfs on /pie-b/dev, changes its root to /pie-b and runs its
 * /sbin/launchd. If any step fails, it reboots.
 */
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <errno.h>
#include <hfs/hfs_mount.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TREE "/pie-b"

static void
fail(const char *what)
{
	fprintf(stderr, "launchd.pieb: %s: %s; rebooting\n", what, strerror(errno));
	sync();
	reboot(RB_AUTOBOOT);
	for (;;) {
		pause();
	}
}

static void
remount_root(void)
{
	struct statfs sfs;
	if (statfs("/", &sfs) != 0) {
		fail("statfs /");
	}
	if (!(sfs.f_flags & MNT_RDONLY)) {
		return;
	}
	struct hfs_mount_args args;
	struct stat st;
	char dev[MAXPATHLEN];
	const char *name;
	void *data = NULL;
	if (strcmp(sfs.f_fstypename, "hfs") == 0) {
		memset(&args, 0, sizeof(args));
		if (stat("/", &st) == 0 && (name = devname(st.st_dev, S_IFBLK)) != NULL) {
			snprintf(dev, sizeof(dev), "/dev/%s", name);
			args.fspec = dev;
		}
		args.hfs_uid = (uid_t)VNOVAL;
		args.hfs_gid = (gid_t)VNOVAL;
		args.hfs_mask = (mode_t)VNOVAL;
		args.hfs_encoding = (u_int32_t)VNOVAL;
		args.hfs_timezone.tz_minuteswest = VNOVAL;
		args.hfs_timezone.tz_dsttime = VNOVAL;
		args.flags = VNOVAL;
		data = &args;
	}
	if (mount(sfs.f_fstypename, "/", (int)(sfs.f_flags & ~MNT_RDONLY) | MNT_UPDATE, data) != 0) {
		fail("mount / read-write");
	}
}

int
main(int argc, char **argv)
{
	(void)argc;
	if (getpid() != 1) {
		fprintf(stderr, "launchd.pieb: not process 1\n");
		return 1;
	}
	remount_root();
	if (mount("devfs", TREE "/dev", MNT_DONTBROWSE, NULL) != 0) {
		fail("mount devfs on " TREE "/dev");
	}
	if (chroot(TREE) != 0 || chdir("/") != 0) {
		fail("chroot " TREE);
	}
	argv[0] = "launchd";
	execv("/sbin/launchd", argv);
	fail("exec " TREE "/sbin/launchd");
	return 1;
}
