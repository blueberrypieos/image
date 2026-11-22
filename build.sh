#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
#
# Build the Blueberry Pie OS SD card images from the packages of an apt
# repository: one with an HFS+ root, for the Raspberry Pi 4 and 5 only,
# and one with a ZFS root, for every board PIE runs on.
#
#   ./build.sh [-r REPO_URL] [-k KEYRING] [-p PACKAGES] [-z PACKAGES] [-x DIR] [-o OUTDIR] VERSION
#
# REPO_URL defaults to https://blueberrypieos.com/apt/, and KEYRING to
# keys/blueberry-pie-os-archive-keyring.gpg. -p names packages to install
# besides the base system, one per line; it defaults to packages. -z names
# the ZFS image's further packages; it defaults to packages-zfs. -x names a
# directory of .deb files that take the place of the repository's packages
# of the same names, or add to them. OUTDIR defaults to out. It gets
# blueberry-pie-os-arm64-VERSION-hfs.img.xz and -zfs.img.xz, a .manifest for
# each, which lists the packages installed, and SHA256SUMS.
# The user pie, uid 501, is in admin, staff and wheel. Its record is in
# OpenDirectory, in /var/db/dslocal, with the password blueberry. sshd
# accepts it from the first boot.
# SOURCE_DATE_EPOCH defaults to the last commit's date. Without git
# history it must be set. With the same packages and the same epoch, the
# images are the same.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO=https://blueberrypieos.com/apt/
KEYRING="$HERE/keys/blueberry-pie-os-archive-keyring.gpg"
PACKAGES="$HERE/packages"
PACKAGES_ZFS="$HERE/packages-zfs"
LOCAL=""
OUTDIR=out
PASSWORD=blueberry
while getopts "r:k:p:z:x:o:" opt; do
	case "$opt" in
		r) REPO="$OPTARG" ;;
		k) KEYRING="$OPTARG" ;;
		p) PACKAGES="$OPTARG" ;;
		z) PACKAGES_ZFS="$OPTARG" ;;
		x) LOCAL="$(cd "$OPTARG" && pwd)" ;;
		o) OUTDIR="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
shift $(( OPTIND - 1 ))
[ $# = 1 ] || { sed -n 5,24p "$0"; exit 2; }
VERSION="$1"
NAME="blueberry-pie-os-arm64-$VERSION"
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
	SOURCE_DATE_EPOCH="$(git -C "$HERE" log -1 --format=%ct)" ||
		{ echo "build.sh: no git history; set SOURCE_DATE_EPOCH" >&2; exit 1; }
fi
case "$SOURCE_DATE_EPOCH" in
	"" | *[!0-9]*) echo "build.sh: SOURCE_DATE_EPOCH is not a number of seconds" >&2; exit 1 ;;
esac
export SOURCE_DATE_EPOCH
export TZ=UTC LC_ALL=C.UTF-8

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$OUTDIR"
FAKEROOT="$W/fakeroot"
: > "$FAKEROOT"
fr() { fakeroot -i "$FAKEROOT" -s "$FAKEROOT" -- "$@"; }

# fetch KIND LIST...: the debs of the packages the lists name, with what they
# need, in $W/debs-KIND, and the manifest. A package in -x's directory
# comes from there.
fetch() {
	local kind="$1" p f args=()
	shift
	declare -A local_pkgs=()
	if [ -n "$LOCAL" ]; then
		for f in "$LOCAL"/*.deb; do
			[ -e "$f" ] && local_pkgs["$(dpkg-deb -f "$f" Package)"]="$f"
		done
	fi
	cat "$@" | while read -r p || [ -n "$p" ]; do
		if [ -n "$p" ] && [ -z "${local_pkgs[$p]:-}" ]; then
			echo "$p"
		fi
	done > "$W/list-$kind"
	while read -r p; do args+=(--package "$p"); done < "$W/list-$kind"
	python3 "$HERE/tools/fetch-repo.py" --repo "$REPO" --keyring "$KEYRING" \
		--debs "$W/debs-$kind" --manifest "$W/$kind.manifest" "${args[@]}"
	for p in "${!local_pkgs[@]}"; do
		if ! grep -qx "$p" "$@" && ! grep -q "^$p " "$W/$kind.manifest"; then
			continue
		fi
		rm -f "$W/debs-$kind/${p}_"*.deb
		cp "${local_pkgs[$p]}" "$W/debs-$kind/"
		grep -v "^$p " "$W/$kind.manifest" > "$W/$kind.manifest.new" || true
		printf '%s %s %s\n' "$p" "$(dpkg-deb -f "${local_pkgs[$p]}" Version)" \
			"$(sha256sum < "${local_pkgs[$p]}" | cut -d ' ' -f 1)" >> "$W/$kind.manifest.new"
		LC_ALL=C sort -o "$W/$kind.manifest" "$W/$kind.manifest.new"
	done
	cp "$W/$kind.manifest" "$OUTDIR/$NAME-$kind.manifest"
}

# add_pie ROOT: pie's record in OpenDirectory, in admin, staff and wheel.
add_pie() {
	local root="$1" g f
	local dslocal="$root/private/var/db/dslocal"
	local node="$dslocal/nodes/Default"
	local templates="$root/usr/share/base-files/dslocal"
	for g in admin staff wheel; do
		[ -f "$templates/groups/$g.plist" ] || { echo "build.sh: base-files has no $g group record" >&2; exit 1; }
	done
	for f in master.passwd passwd; do
		[ -f "$root/private/etc/$f" ] || { echo "build.sh: base-files installs no /etc/$f" >&2; exit 1; }
	done
	if grep -q '^pie:' "$root/private/etc/master.passwd" "$root/private/etc/passwd"; then
		echo "build.sh: pie is in /etc; it belongs only in OpenDirectory" >&2
		exit 1
	fi
	fr install -d -m 755 "$root/private/var/db"
	fr install -d -m 700 "$dslocal" "$dslocal/nodes" "$node" "$node/users" "$node/groups"
	printf '%s\n' "$PASSWORD" | fr python3 "$HERE/tools/dslocal-record" user "$node" --name pie \
		--uid 501 --gid 20 --realname Pie --home /Users/pie --shell /bin/sh \
		--password-stdin --salt-seed "$NAME" > /dev/null
	for g in admin staff wheel; do
		fr python3 "$HERE/tools/dslocal-record" member "$node" --group "$g" --user pie \
			--from "$templates/groups/$g.plist" > /dev/null
	done
}

# check_boot ROOT: the boot files the image needs.
check_boot() {
	local f
	for f in pieboot.bin config.txt start4.elf xnu.bundle; do
		[ -f "$1/usr/lib/blueberry-pie-os/boot/$f" ] ||
			{ echo "build.sh: the packages install no /usr/lib/blueberry-pie-os/boot/$f" >&2; exit 1; }
	done
}

# check_hfs ROOT VOLUME DEB...: the volume has the tree and the debs' modes,
# and fsck.hfsplus leaves it as it is.
check_hfs() {
	local root="$1" vol="$2"
	shift 2
	python3 "$HERE/tools/checkmodes.py" -r "$root" -t "$vol" "$@"
	cp --sparse=always "$vol" "$W/fsck.hfs"
	fsck.hfsplus -f -y "$W/fsck.hfs" > "$W/fsck.log" 2>&1 &&
		cmp -s "$vol" "$W/fsck.hfs" ||
		{ cat "$W/fsck.log" >&2; echo "build.sh: fsck.hfsplus finds the volume damaged" >&2; exit 1; }
	rm "$W/fsck.hfs"
}

fetch hfs "$PACKAGES"
fetch zfs "$PACKAGES" "$PACKAGES_ZFS"

# The HFS+ image.
fr "$HERE/tools/installroot.sh" "$W/root" "$W"/debs-hfs/*.deb
add_pie "$W/root"
check_boot "$W/root"
fr python3 "$HERE/tools/mkhfs.py" -n "Blueberry Pie OS" -s 3072 -J --seed "$NAME" \
	-u "$W/root.uuid" "$W/root" "$W/root.hfs"
check_hfs "$W/root" "$W/root.hfs" "$W"/debs-hfs/*.deb
"$HERE/tools/mkimage.sh" -o "$W/$NAME-hfs.img" -B "$W/root/usr/lib/blueberry-pie-os/boot" \
	-r "$W/root.hfs" -a "serial=3 debug=0x8 rd=uuid boot-uuid=$(cat "$W/root.uuid")"
rm -f "$W/root.hfs"

# The ZFS image.
DATA_PATHS="private/var private/tmp Users Volumes cores usr/local"
fr "$HERE/tools/installroot.sh" "$W/zfull" "$W"/debs-zfs/*.deb
add_pie "$W/zfull"
fr "$HERE/tools/installroot.sh" -z "$W/zroot" "$W"/debs-zfs/*.deb
extra="$(cd "$W/zroot" && for d in $DATA_PATHS; do find "$d" -mindepth 1; done | LC_ALL=C sort)"
if [ "$extra" != "$(printf '%s\n' private/var/lib private/var/lib/dpkg)" ]; then
	printf 'build.sh: the root dataset holds these under the data paths:\n%s\n' "$extra" >&2
	exit 1
fi
fr rm -rf "$W/zroot/private/var/lib"
fr rm -rf "$W/zfull/private/var/lib/dpkg"
fr ln -s ../../../usr/lib/blueberry-pie-os/dpkg "$W/zfull/private/var/lib/dpkg"
for d in $DATA_PATHS; do
	fr cp -a "$W/zfull/$d/." "$W/zroot/$d/"
done
check_boot "$W/zroot"
fr python3 "$HERE/tools/mkhfs.py" -n check -s 1790 --seed "$NAME-zfs" "$W/zroot" "$W/zcheck.hfs"
check_hfs "$W/zroot" "$W/zcheck.hfs" "$W"/debs-zfs/*.deb
rm -f "$W/zcheck.hfs"
POOLGUID="$(printf '%s' "$NAME-zfs" | sha256sum | cut -c 1-15)"
fr pie-makefs -t zfs -T "$SOURCE_DATE_EPOCH" -s 3072m \
	-o poolname=pie -o rootpath=/ -o bootfs=pie/root/1 -o ashift=12 \
	-o poolguid=$(( 16#$POOLGUID )) \
	-o 'fs=pie;canmount=off;mountpoint=none' \
	-o 'fs=pie/root;canmount=off;mountpoint=none' \
	-o 'fs=pie/root/1;mountpoint=/' \
	-o 'fs=pie/data;canmount=off;mountpoint=none' \
	-o 'fs=pie/data/default;mountpoint=/private/var' \
	-o 'fs=pie/data/default/tmp;mountpoint=/private/tmp' \
	-o 'fs=pie/data/default/Users;mountpoint=/Users' \
	-o 'fs=pie/data/default/Volumes;mountpoint=/Volumes' \
	-o 'fs=pie/data/default/cores;mountpoint=/cores' \
	-o 'fs=pie/data/default/local;mountpoint=/usr/local' \
	"$W/pool.zfs" "$W/zroot" > "$W/makefs.log" 2>&1 ||
	{ cat "$W/makefs.log" >&2; echo "build.sh: pie-makefs failed" >&2; exit 1; }
mkdir "$W/zdb"
ln -s "$W/pool.zfs" "$W/zdb/pool.zfs"
zdb -e -p "$W/zdb" -bcc pie > "$W/zdb.log" 2>&1 ||
	{ cat "$W/zdb.log" >&2; echo "build.sh: zdb finds the pool damaged" >&2; exit 1; }
zdb -e -p "$W/zdb" -C pie 2>/dev/null | grep -q 'whole_disk: 0' ||
	{ echo "build.sh: the pool's disk is marked as a whole disk; pie-makefs 2 or later is needed" >&2; exit 1; }
"$HERE/tools/mkimage.sh" -t bf -o "$W/$NAME-zfs.img" -B "$W/zroot/usr/lib/blueberry-pie-os/boot" \
	-r "$W/pool.zfs" -a "serial=3 debug=0x8 rd=uuid boot-uuid=5A465320-626F-6F74-2064-657669636500 zfs_boot=pie"
rm -f "$W/pool.zfs"

for kind in hfs zfs; do
	xz -6 -T0 --block-size=64MiB -c "$W/$NAME-$kind.img" > "$OUTDIR/$NAME-$kind.img.xz"
done
(cd "$OUTDIR" && sha256sum -- "$NAME-hfs.img.xz" "$NAME-hfs.manifest" \
	"$NAME-zfs.img.xz" "$NAME-zfs.manifest" > SHA256SUMS)
echo "build.sh: $OUTDIR/$NAME-hfs.img.xz $OUTDIR/$NAME-zfs.img.xz"
