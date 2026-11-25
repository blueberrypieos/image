#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: backup.sh root@HOST KNOWN_HOSTS OUTPUT
# Copies the boot partition's files, the first 16 MiB and the last 1 MiB
# of its disk, /etc and the dpkg state. On a card made for the RK3566 too,
# the last 1 MiB holds the backup GPT. A long raw read of the boot
# partition stalled a QEMU guest, so there is no raw image: the files,
# their sums, the MBR and the GPT restore it. sectors.txt holds the disk's
# size: the first sector whose read returns no data. A read that fails
# stops the backup. fdisk's size holds only 32 bits, and must be that
# size's low 32 bits.
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
rsh "dd if=/dev/r${DISK#/dev/} bs=1048576 count=16 2>/dev/null" < /dev/null > "$OUT/disk-head.bin"
rsh "/usr/sbin/fdisk /dev/r${DISK#/dev/}" < /dev/null > "$OUT/fdisk.txt" 2>&1 || { say "FAIL: fdisk cannot read $DISK"; exit 1; }
FDISK=$(sed -n 's/^Disk: .*\[\([0-9][0-9]*\) sectors\]$/\1/p' "$OUT/fdisk.txt")
[[ $FDISK =~ ^[0-9]+$ ]] || { say "FAIL: no disk size in fdisk's output"; exit 1; }
SECTORS=$(rrun "d=/dev/r${DISK#/dev/}"'
t=$(mktemp /tmp/pie-pitest.XXXXXX)
trap '\''rm -f "$t"'\'' EXIT
n() {
	dd if="$d" of="$t" bs=512 skip="$1" count=1 2> /dev/null || { echo "reading sector $1 of $d failed" >&2; exit 1; }
	case $(wc -c < "$t" | tr -d " ") in
	512) return 0 ;;
	0) return 1 ;;
	*) echo "a short read of sector $1 of $d" >&2; exit 1 ;;
	esac
}
lo=0 hi=1
while n "$hi"; do
	lo=$hi hi=$((hi * 2))
done
while [ $((hi - lo)) -gt 1 ]; do
	m=$(((lo + hi) / 2))
	if n "$m"; then lo=$m; else hi=$m; fi
done
echo "$hi"' < /dev/null) || { say "FAIL: cannot find the end of $DISK"; exit 1; }
[[ $SECTORS =~ ^[0-9]+$ ]] && ((SECTORS > 32768)) || { say "FAIL: cannot find the end of $DISK"; exit 1; }
((SECTORS % 4294967296 == FDISK)) || { say "FAIL: $DISK ends after $SECTORS sectors, but fdisk says $FDISK"; exit 1; }
echo "$SECTORS" > "$OUT/sectors.txt"
rsh "dd if=/dev/r${DISK#/dev/} bs=512 skip=$((SECTORS - 2048)) count=2048 2>/dev/null" < /dev/null > "$OUT/disk-tail.bin"
rsh 'tar -C / -cf - private/etc 2>/dev/null' < /dev/null > "$OUT/etc.tar"
rsh 'cat /var/lib/dpkg/status' < /dev/null > "$OUT/dpkg-status"
rsh "dpkg-query -W -f='\${Package} \${Version}\n'" < /dev/null > "$OUT/packages.txt"
mkdir "$OUT/fat"
tar -C "$OUT/fat" --exclude='._*' --warning=no-unknown-keyword -xf "$OUT/fat.tar"
(cd "$OUT/fat" && find . -type f -exec sha256sum {} + | sort -k 2) > "$OUT/fat-sums-local.txt"
diff -u "$OUT/fat-sums.txt" "$OUT/fat-sums-local.txt" > "$OUT/fat-sums.diff" || { say "FAIL: the FAT copy differs from the Pi's sums"; exit 1; }
[[ $(stat -c %s "$OUT/disk-head.bin") == 16777216 ]] || { say "FAIL: short disk head"; exit 1; }
[[ $(stat -c %s "$OUT/disk-tail.bin") == 1048576 ]] || { say "FAIL: short disk tail"; exit 1; }
python3 - "$OUT/disk-head.bin" "$OUT/disk-tail.bin" "$SECTORS" > "$OUT/partitions.txt" <<'PY' || { say "FAIL: the disk head holds no MBR with a FAT first"; exit 1; }
import struct, sys
head = open(sys.argv[1], 'rb').read(34 * 512)
tail = open(sys.argv[2], 'rb').read()
mbr = head[:512]
assert mbr[510:] == b'\x55\xaa'
print('disk: %s sectors' % sys.argv[3])
for i in range(4):
    _, _, kind, _, start, count = struct.unpack_from('<B3sB3sII', mbr, 446 + 16 * i)
    if kind:
        print('partition %d: type 0x%02x, sectors %d to %d' % (i + 1, kind, start, start + count - 1))
if head[512:520] == b'EFI PART':
    print('gpt: primary in sector 1, backup named at sector %d' % struct.unpack_from('<Q', head, 512 + 32)[0])
else:
    print('gpt: none in sector 1')
print('gpt: %s in the last sector' % ('a backup header' if tail[-512:-504] == b'EFI PART' else 'no header'))
assert struct.unpack_from('<B3sB3sII', mbr, 446)[2] in (0x0b, 0x0c)
PY
[[ -s $OUT/fat/config.txt ]] || { say "FAIL: no config.txt on the FAT"; exit 1; }
if grep -E ' \./(tryboot\.txt|trial/|pie-stage/|config-pie-|config\.txt\.new$|autoboot\.txt$)' "$OUT/fat-sums.txt"; then
    say "FAIL: the boot partition already holds trial files; tear down first"
    exit 1
fi
(cd "$OUT" && sha256sum devices.txt fat.tar fat-sums.txt disk-head.bin fdisk.txt sectors.txt disk-tail.bin partitions.txt etc.tar dpkg-status packages.txt > SHA256SUMS)
say "backup: $(wc -l < "$OUT/fat-sums.txt") FAT files, $(stat -c %s "$OUT/etc.tar") bytes of /etc"
