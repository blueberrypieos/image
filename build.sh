#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
#
# Build the Blueberry Pie OS SD card image for the Raspberry Pi 4 and 5 from
# the packages of an apt repository.
#
#   ./build.sh [-r REPO_URL] [-k KEYRING] [-p PACKAGES] [-o OUTDIR] VERSION
#
# REPO_URL defaults to https://blueberrypieos.com/apt/, and KEYRING to
# keys/blueberry-pie-os-archive-keyring.gpg. PACKAGES names packages to
# install besides the base system, one per line. It defaults to packages.
# OUTDIR defaults to out. It gets blueberry-pie-os-rpi-VERSION.img.xz,
# its .manifest, which lists the packages installed, and SHA256SUMS.
# The user pie, uid 501, is in admin, staff and wheel. Its record is in
# OpenDirectory, in /var/db/dslocal, with the password blueberry. sshd
# accepts it from the first boot.
# SOURCE_DATE_EPOCH defaults to the last commit's date. Without git
# history it must be set. With the same packages and the same epoch, the
# image is the same.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO=https://blueberrypieos.com/apt/
KEYRING="$HERE/keys/blueberry-pie-os-archive-keyring.gpg"
PACKAGES="$HERE/packages"
OUTDIR=out
PASSWORD=blueberry
while getopts "r:k:p:o:" opt; do
	case "$opt" in
		r) REPO="$OPTARG" ;;
		k) KEYRING="$OPTARG" ;;
		p) PACKAGES="$OPTARG" ;;
		o) OUTDIR="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
shift $(( OPTIND - 1 ))
[ $# = 1 ] || { sed -n 5,20p "$0"; exit 2; }
VERSION="$1"
NAME="blueberry-pie-os-rpi-$VERSION"
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

EXTRA=()
while read -r p || [ -n "$p" ]; do
	[ -n "$p" ] && EXTRA+=(--package "$p")
done < "$PACKAGES"
python3 "$HERE/tools/fetch-repo.py" --repo "$REPO" --keyring "$KEYRING" \
	--debs "$W/debs" --manifest "$OUTDIR/$NAME.manifest" "${EXTRA[@]}"
FAKEROOT="$W/fakeroot"
: > "$FAKEROOT"
fr() { fakeroot -i "$FAKEROOT" -s "$FAKEROOT" -- "$@"; }
fr "$HERE/tools/installroot.sh" "$W/root" "$W"/debs/*.deb

DSLOCAL="$W/root/private/var/db/dslocal"
NODE="$DSLOCAL/nodes/Default"
TEMPLATES="$W/root/usr/share/base-files/dslocal"
for g in admin staff wheel; do
	[ -f "$TEMPLATES/groups/$g.plist" ] || { echo "build.sh: base-files has no $g group record" >&2; exit 1; }
done
for f in master.passwd passwd; do
	[ -f "$W/root/private/etc/$f" ] || { echo "build.sh: base-files installs no /etc/$f" >&2; exit 1; }
done
if grep -q '^pie:' "$W/root/private/etc/master.passwd" "$W/root/private/etc/passwd"; then
	echo "build.sh: pie is in /etc; it belongs only in OpenDirectory" >&2
	exit 1
fi
fr install -d -m 755 "$W/root/private/var/db"
fr install -d -m 700 "$DSLOCAL" "$DSLOCAL/nodes" "$NODE" "$NODE/users" "$NODE/groups"
printf '%s\n' "$PASSWORD" | fr python3 "$HERE/tools/dslocal-record" user "$NODE" --name pie \
	--uid 501 --gid 20 --realname Pie --home /Users/pie --shell /bin/sh \
	--password-stdin --salt-seed "$NAME" > /dev/null
for g in admin staff wheel; do
	fr python3 "$HERE/tools/dslocal-record" member "$NODE" --group "$g" --user pie \
		--from "$TEMPLATES/groups/$g.plist" > /dev/null
done

BOOT="$W/root/usr/lib/blueberry-pie-os/boot"
for f in pieboot.bin config.txt start4.elf xnu.bundle; do
	[ -f "$BOOT/$f" ] || { echo "build.sh: the packages install no $BOOT/$f" >&2; exit 1; }
done

fr python3 "$HERE/tools/mkhfs.py" -n "Blueberry Pie OS" -s 1790 -J --seed "$NAME" \
	-u "$W/root.uuid" "$W/root" "$W/root.hfs"
python3 "$HERE/tools/checkmodes.py" -r "$W/root" -t "$W/root.hfs" "$W"/debs/*.deb
cp "$W/root.hfs" "$W/fsck.hfs"
fsck.hfsplus -f -y "$W/fsck.hfs" > "$W/fsck.log" 2>&1 &&
	cmp -s "$W/root.hfs" "$W/fsck.hfs" ||
	{ cat "$W/fsck.log" >&2; echo "build.sh: fsck.hfsplus finds the volume damaged" >&2; exit 1; }
rm "$W/fsck.hfs"
"$HERE/tools/mkimage.sh" -o "$W/$NAME.img" -B "$BOOT" -r "$W/root.hfs" \
	-a "serial=3 debug=0x8 rd=uuid boot-uuid=$(cat "$W/root.uuid")"
xz -6 -T0 --block-size=64MiB -c "$W/$NAME.img" > "$OUTDIR/$NAME.img.xz"
(cd "$OUTDIR" && sha256sum -- "$NAME.img.xz" "$NAME.manifest" > SHA256SUMS)
echo "build.sh: $OUTDIR/$NAME.img.xz"
