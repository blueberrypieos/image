#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: backup.sh root@HOST KNOWN_HOSTS OUTPUT
# Copies the boot partition's files, the first MB of its disk, /etc and the
# dpkg state. A long raw read of the boot partition stalled a QEMU guest, so
# there is no raw image: the files, their sums and the MBR restore it.
[[ $# == 3 ]] || { sed -n '4p' "$0" >&2; exit 2; }
HOST=$1 KNOWN=$2 OUT=$3
source "$(dirname -- "$0")/lib.sh"
[[ ! -e $OUT/SHA256SUMS ]] || { echo 'Use a new output directory.' >&2; exit 2; }
say "backup of $HOST"
rrun 'set -eu
fat_find
echo "$disk $boot"' > "$OUT/devices.txt" < /dev/null
read -r DISK BOOT < "$OUT/devices.txt"
[[ $DISK =~ ^/dev/disk[0-9]+$ && $BOOT == "${DISK}s1" ]] || { say "FAIL: odd devices: $DISK $BOOT"; exit 1; }
rrun 'set -eu
fat_mount rdonly
trap fat_umount EXIT
tar -C "$FAT" -cf - .' > "$OUT/fat.tar" 2> "$OUT/fat-copy.txt" < /dev/null
rrun 'set -eu
fat_mount rdonly
trap fat_umount EXIT
fat_sums' > "$OUT/fat-sums.txt" < /dev/null
rsh "dd if=/dev/r${DISK#/dev/} bs=512 count=2048 2>/dev/null" < /dev/null > "$OUT/disk-head.bin"
rsh 'tar -C / -cf - private/etc 2>/dev/null' < /dev/null > "$OUT/etc.tar"
rsh 'cat /var/lib/dpkg/status' < /dev/null > "$OUT/dpkg-status"
rsh "dpkg-query -W -f='\${Package} \${Version}\n'" < /dev/null > "$OUT/packages.txt"
mkdir "$OUT/fat"
tar -C "$OUT/fat" --exclude='._*' --warning=no-unknown-keyword -xf "$OUT/fat.tar"
(cd "$OUT/fat" && find . -type f -exec sha256sum {} + | sort -k 2) > "$OUT/fat-sums-local.txt"
diff -u "$OUT/fat-sums.txt" "$OUT/fat-sums-local.txt" > "$OUT/fat-sums.diff" || { say "FAIL: the FAT copy differs from the Pi's sums"; exit 1; }
[[ $(stat -c %s "$OUT/disk-head.bin") == 1048576 ]] || { say "FAIL: short disk head"; exit 1; }
python3 - "$OUT/disk-head.bin" > "$OUT/partitions.txt" <<'PY' || { say "FAIL: the disk head holds no MBR with a FAT first"; exit 1; }
import struct, sys
mbr = open(sys.argv[1], 'rb').read(512)
assert mbr[510:] == b'\x55\xaa'
for i in range(4):
    _, _, kind, _, start, count = struct.unpack_from('<B3sB3sII', mbr, 446 + 16 * i)
    if kind:
        print('partition %d: type 0x%02x, sectors %d to %d' % (i + 1, kind, start, start + count - 1))
assert struct.unpack_from('<B3sB3sII', mbr, 446)[2] in (0x0b, 0x0c)
PY
[[ -s $OUT/fat/config.txt ]] || { say "FAIL: no config.txt on the FAT"; exit 1; }
if grep -E ' \./(tryboot\.txt|trial/|pie-stage/|config-pie-|config\.txt\.new$|autoboot\.txt$)' "$OUT/fat-sums.txt"; then
    say "FAIL: the boot partition already holds trial files; tear down first"
    exit 1
fi
(cd "$OUT" && sha256sum devices.txt fat.tar fat-sums.txt disk-head.bin partitions.txt etc.tar dpkg-status packages.txt > SHA256SUMS)
say "backup: $(wc -l < "$OUT/fat-sums.txt") FAT files, $(stat -c %s "$OUT/etc.tar") bytes of /etc"
