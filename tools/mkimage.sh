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
# image ends at the root partition's end, rounded up to a whole MiB, and
# 1 MiB more that no partition covers. The first boot keeps that last MiB
# out of the root when it grows it. The sectors between the MBR and the
# boot partition are zero. -l writes LOADER there, at sector 64, where the
# RK3566 looks for its loader. LOADER must end before sector 24576. -l also
# writes a GPT with one partition, uboot, at sectors 16384 to 24575, where
# the loader's FIT starts: the loader on the RG353V's eMMC loads U-Boot
# from a card only through that partition. The GPT's primary copy is in
# sectors 1 to 33, and its backup in the image's last 33 sectors. The MBR
# has no 0xEE entry, so PIE, U-Boot and Linux read only the MBR.
# The boot partition's files go in sorted by name. With SOURCE_DATE_EPOCH
# set, they carry that date.
# Needs dosfstools, mtools, sfdisk from fdisk, and python3 for -l.
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
LOADER_END=24576

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
	if [ $(( LOADER_START + (LOADER_SIZE + 511) / 512 )) -gt "$LOADER_END" ]; then
		echo "mkimage.sh: $LOADER does not end before sector $LOADER_END" >&2
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
TOTAL_MB=$(( (ROOT_START + ROOT_SECTORS + 2047) / 2048 + 1 ))
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
	python3 -I - "$OUT" $(( TOTAL_MB * 2048 )) <<'PY'
import struct, sys, uuid, zlib
img, n = sys.argv[1], int(sys.argv[2])
ents = bytearray(128 * 128)
struct.pack_into("<16s16sQQQ", ents, 0, uuid.UUID("a60b0000-0000-4c7e-8000-015e00004db7").bytes_le,
                 uuid.UUID("7d0d0b55-3a81-51a3-8d9a-f5879dced4ce").bytes_le, 16384, 24575, 0)
ents[56:66] = "uboot".encode("utf-16-le")


def header(my, alt, at):
    h = bytearray(512)
    struct.pack_into("<8sIIIIQQQQ16sQIII", h, 0, b"EFI PART", 0x10000, 92, 0, 0, my, alt, 34, n - 34,
                     uuid.UUID("9aca35a7-0f48-51bf-85e1-ce97d9283284").bytes_le, at, 128, 128, zlib.crc32(ents))
    struct.pack_into("<I", h, 16, zlib.crc32(h[:92]))
    return bytes(h)


with open(img, "r+b") as f:
    f.seek(512)
    f.write(header(1, n - 1, 2) + ents)
    f.seek((n - 33) * 512)
    f.write(ents + header(n - 1, 1, n - 33))
PY
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
