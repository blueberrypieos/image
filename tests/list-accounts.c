/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 The Blueberry Pie OS Authors
 *
 * usage: list-accounts
 *
 * Prints "user NAME" for each getpwent(3) entry, then "group NAME" for
 * each getgrent(3) entry.
 */
#include <grp.h>
#include <pwd.h>
#include <stdio.h>

int
main(void)
{
	struct passwd *pw;
	struct group *gr;

	setpwent();
	while ((pw = getpwent()) != NULL) {
		printf("user %s\n", pw->pw_name);
	}
	endpwent();
	setgrent();
	while ((gr = getgrent()) != NULL) {
		printf("group %s\n", gr->gr_name);
	}
	endgrent();
	return fflush(stdout) != 0 || ferror(stdout) ? 1 : 0;
}
