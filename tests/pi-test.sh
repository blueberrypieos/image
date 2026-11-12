#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: pi-test.sh pie@HOST KNOWN_HOSTS MANIFEST OUTPUT
set -euo pipefail
[[ $# == 4 ]] || { sed -n '4p' "$0" >&2; exit 2; }
HOST=$1
KNOWN=$(realpath -- "$2")
MANIFEST=$(realpath -- "$3")
OUT=$4
[[ $HOST == pie@* && $HOST != -* ]] || { echo 'Use pie@HOST.' >&2; exit 2; }
[[ -n ${PI_LEASE:-} ]] || { echo 'Take a Pi lease first. Set PI_LEASE to its name.' >&2; exit 2; }
: "${PI_CONSOLE_LOG:?Set PI_CONSOLE_LOG to a live serial console capture.}"
source "$(dirname -- "$0")/common.sh"
prepare
cat > "$OUT/askpass" <<'SH'
#!/bin/sh
printf '%s\n' "$PIE_PASSWORD"
SH
chmod 700 "$OUT/askpass"
export SSH_ASKPASS=$OUT/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=:0
export PIE_PASSWORD=${PIE_PASSWORD:-blueberry}
SSH=(ssh -F /dev/null -o ConnectTimeout=5 -o ServerAliveInterval=15 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN"
    -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 "$HOST")
ADMIN_SSH=("${SSH[@]}")
console_check() {
    tail -c +$((${1:-0} + 1)) -- "$PI_CONSOLE_LOG" > "$OUT/console.log"
    if grep -aE '(^|[[:space:]])login:' "$OUT/console.log" > "$OUT/login.txt"; then record PASS login; else record FAIL login; fi
    if grep -aF 'panic(cpu' "$OUT/console.log" > "$OUT/console-panics.txt"; then record FAIL console-panics; else record PASS console-panics; fi
}
snapshot() {
    privileged 'set -e; uname -v; sysctl kern.uuid kern.boottime hw.memsize_usable; kextstat; dpkg-query -W; ioreg -p IODeviceTree -n chosen -l -w0; ls /dev; dmesg'
}
console_check
if snapshot > "$OUT/before.txt" 2>&1; then record PASS before; else record FAIL before; fi
mkdir "$OUT/fat"
if privileged_input 'sh -s' > "$OUT/fat.tar" 2> "$OUT/fat-copy.txt" <<'SH'
set -eu
root=$(df / | awk 'NR == 2 {print $1}')
boot="${root%s*}s1"
w=$(mktemp -d /tmp/pie-check.XXXXXX)
trap 'umount "$w"; rmdir "$w"' EXIT
mount_msdos -o rdonly "$boot" "$w"
tar -C "$w" -cf - .
SH
then record PASS fat-copy; else record FAIL fat-copy; fi
check fat-extract tar -xf "$OUT/fat.tar" -C "$OUT/fat"
sha256sum "$OUT"/fat/pieboot.bin "$OUT"/fat/*.dtb "$OUT"/fat/xnu.bundle > "$OUT/boot-hashes.txt"
compare_bundle
check console-kernel python3 "$HERE/kernel.py" "$OUT/fat/xnu.bundle" "$OUT/console-members" "$OUT/console.log"
collect
check boot-time-before remote 'sysctl -n kern.boottime'
check fat-before privileged_input 'sh -s' <<'SH'
set -eu
root=$(df / | awk 'NR == 2 {print $1}')
boot="${root%s*}s1"
w=$(mktemp -d /tmp/pie-check.XXXXXX)
l=$(mktemp /tmp/pie-check.XXXXXX)
trap 'rm -f "$l"; umount "$w"; rmdir "$w"' EXIT
mount_msdos -o rdonly "$boot" "$w"
(cd "$w" && find . -type f -exec sha256sum {} +) > "$l"
sort -k 2 "$l"
SH
if ((FAILED)); then echo 'Checks failed. No reboot.' > "$OUT/reboot.txt"; exit 1; fi
mkdir "$OUT/before-checks"
for f in "$OUT"/*.txt; do
    [[ $f == "$OUT/results.txt" ]] || cp "$f" "$OUT/before-checks/"
done
CONSOLE_BEFORE=$(wc -c < "$PI_CONSOLE_LOG")
privileged 'sync; shutdown -r now' > "$OUT/reboot.txt" 2>&1 &
RP=$!
DOWN=0
for ((n=0;n<60;n++)); do
    if ! remote true >> "$OUT/reboot-probe.txt" 2>&1; then DOWN=1; break; fi
    sleep 2
done
wait "$RP" || true
if ((!DOWN)); then record FAIL reboot-disconnect; exit 1; fi
record PASS reboot-disconnect
UP=0
for ((n=0;n<180;n++)); do
    if remote true >> "$OUT/reboot-probe.txt" 2>&1; then UP=1; break; fi
    sleep 2
done
if ((!UP)); then record FAIL reboot-return; exit 1; fi
record PASS reboot-return
check boot-time-after remote 'sysctl -n kern.boottime'
if cmp -s "$OUT/boot-time-before.txt" "$OUT/boot-time-after.txt"; then record FAIL reboot-time; else record PASS reboot-time; fi
console_check "$CONSOLE_BEFORE"
if snapshot > "$OUT/after.txt" 2>&1; then record PASS after; else record FAIL after; fi
collect
check fat-after privileged_input 'sh -s' <<'SH'
set -eu
root=$(df / | awk 'NR == 2 {print $1}')
boot="${root%s*}s1"
w=$(mktemp -d /tmp/pie-check.XXXXXX)
l=$(mktemp /tmp/pie-check.XXXXXX)
trap 'rm -f "$l"; umount "$w"; rmdir "$w"' EXIT
mount_msdos -o rdonly "$boot" "$w"
(cd "$w" && find . -type f -exec sha256sum {} +) > "$l"
sort -k 2 "$l"
SH
check fat-unchanged diff -u "$OUT/fat-before.txt" "$OUT/fat-after.txt"
for name in uname uuid kernel-file kextstat packages; do
    check "$name-unchanged" diff -u "$OUT/before-checks/$name.txt" "$OUT/$name.txt"
done
printf 'exit=%s\n' "$FAILED" | tee "$OUT/exit.txt"
exit "$FAILED"
