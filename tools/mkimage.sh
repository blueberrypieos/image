#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
#
# Build a PIE SD card image: an MBR disk with a FAT32 boot partition and a
# root partition, HFS+ or a ZFS pool.
#
#   tools/mkimage.sh -o OUT.img -B BOOTDIR -r ROOT.img [-t TYPE] [-a BOOT-ARGS] [-s SIZE_MB] [-l LOADER]
#
# BOOTDIR holds the boot partition's files. The packages install them in
# /usr/lib/blueberry-pie-os/boot. TYPE is the root partition's MBR type: af
# for HFS+, the default, or bf for ZFS. BOOT-ARGS go into cmdline.txt. -s
# is the boot partition's size in MiB, 512 by default. The boot partition
# starts at 16 MiB, sector 32768, and the root partition follows it. The
# sectors between the MBR and the boot partition are zero. -l writes LOADER
# there, at sector 64, where the RK3566 looks for its loader. LOADER must
# end before sector 32768. The image ends at the root partition's end,
# rounded up to a whole MiB.
# The boot partition's files go in sorted by name. With SOURCE_DATE_EPOCH
# set, they carry that date.
# Needs dosfstools, mtools and sfdisk from fdisk.
set -euo pipefail

OUT=""
BOOT=""
ARGS=""
SIZE_MB=512
ROOT=""
TYPE=af
LOADER=""
FAT_START=32768
LOADER_START=64

while getopts "o:B:a:s:r:t:l:" opt; do
	case "$opt" in
		t) TYPE="$OPTARG" ;;
		o) OUT="$OPTARG" ;;
		B) BOOT="$OPTARG" ;;
		a) ARGS="$OPTARG" ;;
		s) SIZE_MB="$OPTARG" ;;
		r) ROOT="$OPTARG" ;;
		l) LOADER="$OPTARG" ;;
		*) exit 1 ;;
	esac
done
[ -n "$OUT" ] && [ -d "$BOOT" ] && [ -f "$ROOT" ] || { sed -n '5,/^# Needs /p' "$0"; exit 1; }
if [ -n "$LOADER" ]; then
	[ -f "$LOADER" ] || { echo "mkimage.sh: no loader $LOADER" >&2; exit 1; }
	LOADER_SIZE=$(stat -L -c %s -- "$LOADER")
	if [ $(( LOADER_START + (LOADER_SIZE + 511) / 512 )) -gt "$FAT_START" ]; then
		echo "mkimage.sh: $LOADER does not end before sector $FAT_START" >&2
		exit 1
	fi
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -RL "$BOOT"/. "$STAGE"/
printf '%s\n' "$ARGS" > "$STAGE/cmdline.txt"
chmod -R u+rwX,go+rX,go-w "$STAGE"
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
fi

PART_SECTORS=$(( SIZE_MB * 2048 ))
ROOT_START=$(( FAT_START + PART_SECTORS ))
ROOT_SIZE=$(stat -L -c %s -- "$ROOT")
ROOT_SECTORS=$(( (ROOT_SIZE + 511) / 512 ))
TOTAL_MB=$(( (ROOT_START + ROOT_SECTORS + 2047) / 2048 ))
rm -f "$OUT"
truncate -s "${TOTAL_MB}M" "$OUT"
{
	echo 'label: dos'
	echo 'label-id: 0x42504f53'
	echo "start=$FAT_START, size=$PART_SECTORS, type=c, bootable"
	echo "start=$ROOT_START, size=$ROOT_SECTORS, type=$TYPE"
} | sfdisk -q "$OUT"
SPC=8
while [ "$SPC" -gt 1 ] && [ $(( PART_SECTORS / SPC )) -lt 70000 ]; do SPC=$(( SPC / 2 )); done
mkfs.vfat -F 32 -s "$SPC" -n PIEBOOT --invariant --offset "$FAT_START" "$OUT" $(( PART_SECTORS / 2 )) > /dev/null
if [ -n "$LOADER" ]; then
	dd if="$LOADER" of="$OUT" bs=512 seek="$LOADER_START" conv=notrunc,sparse status=none
fi
dd if="$ROOT" of="$OUT" bs=512 seek="$ROOT_START" conv=notrunc,sparse status=none

export MTOOLS_SKIP_CHECK=1
FAT="$OUT@@$(( FAT_START * 512 ))"
SKEL="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$SKEL"' EXIT
n=0
(cd "$STAGE" && find . -mindepth 1 -print0) | LC_ALL=C sort -z | while IFS= read -r -d '' p; do
	p="${p#./}"
	name="${p##*/}"
	if [ -d "$STAGE/$p" ]; then
		n=$(( n + 1 ))
		mkdir -p "$SKEL/$n/$name"
		touch -r "$STAGE/$p" "$SKEL/$n/$name"
		mcopy -s -m -i "$FAT" "$SKEL/$n/$name" "::/${p%"$name"}"
	else
		mcopy -m -i "$FAT" "$STAGE/$p" "::/$p"
	fi
done
echo "image: $OUT"
