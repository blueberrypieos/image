#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
#
# Build a Raspberry Pi SD card image: an MBR disk with a FAT32 boot
# partition and an HFS+ root partition.
#
#   tools/mkimage.sh -o OUT.img -B BOOTDIR -r ROOT.hfs [-a BOOT-ARGS] [-s SIZE_MB]
#
# BOOTDIR holds the boot partition's files. The packages install them in
# /usr/lib/blueberry-pie-os/boot. BOOT-ARGS go into cmdline.txt. -s is the
# boot partition's size in MB, 256 by default. The image size is rounded
# up to a power of two. The boot partition's files go in sorted by name.
# With SOURCE_DATE_EPOCH set, they carry that date.
# Needs dosfstools, mtools and sfdisk from fdisk.
set -euo pipefail

OUT=""
BOOT=""
ARGS=""
SIZE_MB=256
ROOT=""

while getopts "o:B:a:s:r:" opt; do
	case "$opt" in
		o) OUT="$OPTARG" ;;
		B) BOOT="$OPTARG" ;;
		a) ARGS="$OPTARG" ;;
		s) SIZE_MB="$OPTARG" ;;
		r) ROOT="$OPTARG" ;;
		*) exit 1 ;;
	esac
done
[ -n "$OUT" ] && [ -d "$BOOT" ] && [ -f "$ROOT" ] || { sed -n 5,15p "$0"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -RL "$BOOT"/. "$STAGE"/
printf '%s\n' "$ARGS" > "$STAGE/cmdline.txt"
chmod -R u+rwX,go+rX,go-w "$STAGE"
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
fi

PART_SECTORS=$(( SIZE_MB * 2048 ))
ROOT_START=$(( 2048 + PART_SECTORS ))
ROOT_SECTORS=$(( ($(stat -c %s "$ROOT") + 511) / 512 ))
TOTAL_MB=$(( (ROOT_START + ROOT_SECTORS + 2047) / 2048 ))
IMG_MB=1
while [ "$IMG_MB" -lt "$TOTAL_MB" ]; do IMG_MB=$(( IMG_MB * 2 )); done
rm -f "$OUT"
truncate -s "${IMG_MB}M" "$OUT"
{
	echo 'label: dos'
	echo 'label-id: 0x42504f53'
	echo "start=2048, size=$PART_SECTORS, type=c, bootable"
	echo "start=$ROOT_START, size=$ROOT_SECTORS, type=af"
} | sfdisk -q "$OUT"
SPC=8
while [ "$SPC" -gt 1 ] && [ $(( PART_SECTORS / SPC )) -lt 70000 ]; do SPC=$(( SPC / 2 )); done
mkfs.vfat -F 32 -s "$SPC" -n PIEBOOT --invariant --offset 2048 "$OUT" $(( PART_SECTORS / 2 )) > /dev/null
dd if="$ROOT" of="$OUT" bs=512 seek="$ROOT_START" conv=notrunc status=none

export MTOOLS_SKIP_CHECK=1
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
		mcopy -s -m -i "$OUT@@1M" "$SKEL/$n/$name" "::/${p%"$name"}"
	else
		mcopy -m -i "$OUT@@1M" "$STAGE/$p" "::/$p"
	fi
done
echo "image: $OUT"
