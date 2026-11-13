#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: inventory.sh root@HOST KNOWN_HOSTS OUTPUT
# Reads the Pi's state over ssh and changes nothing on it.
[[ $# == 3 ]] || { sed -n '4p' "$0" >&2; exit 2; }
HOST=$1 KNOWN=$2 OUT=$3
source "$(dirname -- "$0")/lib.sh"
say "inventory of $HOST"
INVENTORY=$(cat <<'SH'
section() { printf '\n=== %s\n' "$1"; }
section system; uname -a; sysctl kern.uuid kern.bootargs kern.boottime kern.osversion hw.memsize hw.ncpu 2>&1
section watchdog; sysctl -a 2>/dev/null | grep -i -e watchdog -e '^bbpos' -e '^pie' || echo none
section firmware; ioreg -l -w0 2>/dev/null | grep -i -e 'firmware' -e 'board-rev' | head -20 || true
section chosen; ioreg -p IODeviceTree -n chosen -l -w0 2>/dev/null | grep -v -e 'random-seed' | head -60 || true
section kexts; kextstat 2>&1 | head -60
section packages; dpkg-query -W -f='${Package} ${Version} ${Status}\n' 2>&1
section dpkg-audit; dpkg --audit 2>&1
section apt-sources; ls -l /etc/apt/sources.list /etc/apt/sources.list.d 2>&1; cat /etc/apt/sources.list /etc/apt/sources.list.d/* 2>&1
section sshd; cat /etc/ssh/sshd_config 2>&1 | grep -v -e '^#' -e '^$'; ls /etc/ssh/sshd_config.d 2>&1; /usr/sbin/sshd -T 2>&1 | grep -i -e permitrootlogin -e usepam -e passwordauth -e pubkeyauth -e include
section accounts; grep -v '^#' /etc/passwd 2>&1; ls /var/db/dslocal/nodes/Default/users 2>&1; ls -l /var/root/.ssh /Users/*/.ssh 2>&1
section tools; for t in sha256sum shasum fdisk gpt dd mount_msdos fsck_hfs newfs_hfs diskutil sysctl ioreg reboot shutdown; do printf '%s: %s\n' "$t" "$(command -v $t || echo missing)"; done
section df; df -k 2>&1
section mounts; mount 2>&1
section disks; ls -l /dev/disk* /dev/rdisk* 2>&1
section media; ioreg -c IOMedia -r -l -w0 2>/dev/null | grep -e 'BSD Name' -e '"Size"' -e '"Preferred Block Size"' -e '"Content"' -e 'Whole' || true
section mbr; dd if=/dev/rdisk0 bs=512 count=1 2>/dev/null | od -A d -t x1 | sed -n '28,33p'
section rdisk0-rw; if (exec 3<>/dev/rdisk0) 2>/dev/null; then echo "rdisk0 opens read-write"; else echo "rdisk0 does not open read-write"; fi
section fat; fat_mount rdonly && { ls -la "$FAT"; ls -la "$FAT/overlays" 2>/dev/null | head -5; fat_sums; for f in config.txt usercfg.txt cmdline.txt tryboot.txt; do printf '\n--- %s\n' "$f"; cat "$FAT/$f" 2>&1; done; fat_umount; }
section panics; ls -l /var/log/panic-* 2>&1 | tail -5
SH
)
rrun "$INVENTORY" > "$OUT/inventory.txt" 2>&1 < /dev/null || { say "inventory failed"; exit 1; }
sed -n '/^=== system/,/^=== chosen/p' "$OUT/inventory.txt" | head -30 >&2
say "inventory written: $OUT/inventory.txt"
