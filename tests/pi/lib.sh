#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: source lib.sh from a tests/pi script, with HOST, KNOWN and OUT set.
set -euo pipefail
export LC_ALL=C
[[ $HOST == root@* && $HOST != -* ]] || { echo 'Use root@HOST.' >&2; exit 2; }
KNOWN=$(realpath -- "$KNOWN")
mkdir -p -- "$OUT"
OUT=$(cd -- "$OUT" && pwd)
ROOT_SSH=(ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$KNOWN" -p "${PI_SSH_PORT:-22}" "$HOST")
say() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT/log.txt" >&2; }
rsh() { "${ROOT_SSH[@]}" "$@"; }
rrun() {
    local script=$1 tmp rc=0
    tmp=$(rsh 'mktemp /tmp/pie-pitest.XXXXXX' < /dev/null) || return 1
    if ! printf '%s\n%s\n' "$FAT_SH" "$script" | rsh "cat > $tmp"; then
        rsh "rm -f $tmp" < /dev/null || true
        return 1
    fi
    rsh "trap 'rm -f $tmp' EXIT HUP INT TERM; sh $tmp" || rc=$?
    return "$rc"
}
push() {
    local src=$1 dst=$2 size sum chunk=4 n i tries part got
    size=$(stat -c %s "$src")
    sum=$(sha256sum < "$src" | cut -d' ' -f1)
    n=$(( (size + chunk * 1048576 - 1) / (chunk * 1048576) ))
    rsh "rm -f '$dst.part' && : > '$dst.part'" < /dev/null || return 1
    for ((i = 0; i < n; i++)); do
        for ((tries = 0; tries < 5; tries++)); do
            part=$(( size - i * chunk * 1048576 ))
            ((part > chunk * 1048576)) && part=$((chunk * 1048576))
            if dd if="$src" bs=1048576 skip=$((i * chunk)) count=$chunk status=none |
                timeout 300 "${ROOT_SSH[@]}" "dd of='$dst.part' bs=1048576 seek=$((i * chunk)) conv=notrunc 2>/dev/null"; then
                got=$(timeout 60 "${ROOT_SSH[@]}" "dd if='$dst.part' bs=1048576 skip=$((i * chunk)) count=$chunk 2>/dev/null | wc -c" < /dev/null | tr -d ' ') || got=
                [[ $got == "$part" ]] && break
            fi
            say "push: piece $i of $n failed, trying again"
            sleep 5
        done
        ((tries < 5)) || { say "FAIL: push of $src stopped at piece $i"; return 1; }
        sleep 1
    done
    rsh "s=\$(if command -v sha256sum > /dev/null; then sha256sum '$dst.part'; else shasum -a 256 '$dst.part'; fi | cut -d' ' -f1); [ \"\$s\" = $sum ] && mv '$dst.part' '$dst'" < /dev/null ||
        { say "FAIL: $dst arrived damaged"; return 1; }
}
FAT_SH='
fat_find() {
	root=$(df / | awk "NR == 2 {print \$1}")
	boot="${root%s*}s1"
	disk="${root%s*}"
	case "$boot" in /dev/disk[0-9]*s1) ;; *) echo "no boot slice for $root" >&2; return 1 ;; esac
	rec=$(mount | grep -F "$boot on " || true)
	FAT=
	FAT_OWN=
	[ -n "$rec" ] || return 0
	[ "$(printf "%s\n" "$rec" | wc -l)" -eq 1 ] || { echo "$boot is mounted more than once" >&2; return 1; }
	FAT=$(printf "%s\n" "$rec" | sed -n "s#^$boot on \(/[^ ]*\) (.*#\1#p")
	[ -n "$FAT" ] || { echo "cannot read the mount point of $boot: $rec" >&2; return 1; }
	FAT_RO=
	case "$rec" in *read-only*) FAT_RO=1 ;; esac
}
fat_mount() {
	fat_find || return 1
	if [ -n "$FAT" ]; then
		if [ "$1" != rdonly ] && [ -n "$FAT_RO" ]; then
			echo "$boot is mounted read-only at $FAT" >&2
			return 1
		fi
		return 0
	fi
	FAT=$(mktemp -d /tmp/pie-pitest.XXXXXX)
	FAT_OWN=1
	if [ "$1" = rdonly ]; then
		mount_msdos -o rdonly "$boot" "$FAT" || { rmdir "$FAT"; FAT_OWN=; return 1; }
	else
		mount_msdos "$boot" "$FAT" || { rmdir "$FAT"; FAT_OWN=; return 1; }
	fi
}
fat_lock() {
	mkdir /tmp/pie-pitest-fat.lock 2> /dev/null || {
		echo "another tests/pi script is changing the boot partition. If none runs, remove /tmp/pie-pitest-fat.lock" >&2
		exit 1
	}
}
fat_unlock() {
	rmdir /tmp/pie-pitest-fat.lock 2> /dev/null || true
}
fat_umount() {
	[ -n "$FAT_OWN" ] || return 0
	cd /
	sync
	umount "$FAT" && rmdir "$FAT"
}
sum() {
	if command -v sha256sum > /dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
fat_sums() {
	list=$(mktemp /tmp/pie-pitest.XXXXXX)
	if (cd "$FAT" && find . -type f -exec sh -c "if command -v sha256sum > /dev/null; then sha256sum \"\$@\"; else shasum -a 256 \"\$@\"; fi" sh {} +) > "$list"; then
		sort -k 2 "$list"
		rm -f "$list"
	else
		rm -f "$list"
		echo "hashing the boot partition failed" >&2
		return 1
	fi
}
'
