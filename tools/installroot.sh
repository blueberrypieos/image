#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
#
# Install packages into a root tree with the build host's dpkg, as
# debootstrap would. The tree gets the files, and a dpkg database in
# /private/var/lib/dpkg that lists them.
#
#   tools/installroot.sh [-z] ROOT DEB...
#
# With -z, as for a ZFS root, dpkg leaves out /private/var, /private/tmp,
# /Users, /Volumes, /cores and /usr/local, and its database is in
# /usr/lib/blueberry-pie-os/dpkg, which /private/var/lib/dpkg links to.
# The empty directories dpkg still makes there are removed, as dpkg on the
# system does not make them.
#
# Maintainer scripts run on the host with DPKG_ROOT set; nothing inside
# ROOT runs. Run it under fakeroot, saved with -s, and run mkhfs.py in
# that session, resumed with -i. The volume then gets the debs' modes,
# owners and groups.
set -euo pipefail
ZFS=
[ "${1:-}" = -z ] && { ZFS=1; shift; }
[ $# -ge 2 ] || { sed -n 5,20p "$0"; exit 2; }
ROOT="$1"
shift
umask 022
install -d -m 755 "$ROOT"
ROOT="$(cd "$ROOT" && pwd)"

install -d -m 755 "$ROOT"/private/{etc,var}
install -d -m 1777 "$ROOT"/private/tmp
for d in etc tmp var; do
	[ -L "$ROOT/$d" ] || ln -sfn "private/$d" "$ROOT/$d"
done
ADMIN="$ROOT/private/var/lib/dpkg"
EXCLUDE=()
if [ -n "$ZFS" ]; then
	ADMIN="$ROOT/usr/lib/blueberry-pie-os/dpkg"
	install -d -m 755 "$ROOT/private/var/lib" "$ROOT/usr" "$ROOT/usr/lib" "$ROOT/usr/lib/blueberry-pie-os"
	ln -s ../../../usr/lib/blueberry-pie-os/dpkg "$ROOT/private/var/lib/dpkg"
	for d in /private/var /private/tmp /Users /Volumes /cores /usr/local; do
		EXCLUDE+=(--path-exclude="$d/*")
	done
fi
mkdir -p "$ADMIN"/{info,updates,triggers}
touch "$ADMIN"/{status,available}
echo darwin-arm64 > "$ADMIN/arch"

DPKG=(dpkg --root="$ROOT" --admindir="$ADMIN" --force-not-root --force-script-chrootless --log=/dev/null)
"${DPKG[@]}" --path-include='/*' "${EXCLUDE[@]}" --no-triggers -i "$@" > /dev/null
"${DPKG[@]}" --triggers-only --pending > /dev/null
audit="$("${DPKG[@]}" --audit)" || { printf '%s\n' "$audit" >&2; exit 1; }
if [ -n "$ZFS" ]; then
	for d in private/var private/tmp Users Volumes cores usr/local; do
		find "$ROOT/$d" -mindepth 1 -depth -type d -empty -delete
	done
fi
[ -z "$audit" ] || { printf 'installroot.sh: dpkg --audit:\n%s\n' "$audit" >&2; exit 1; }
rm -f "$ADMIN"/*-old
