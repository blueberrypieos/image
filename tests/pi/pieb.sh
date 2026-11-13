#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: pieb.sh install root@HOST KNOWN_HOSTS OUTPUT ROOT.tar PIEB-INIT
#        pieb.sh remove root@HOST KNOWN_HOSTS OUTPUT
#        pieb.sh rootkey root@HOST KNOWN_HOSTS OUTPUT KEY.pub
#        pieb.sh norootkey root@HOST KNOWN_HOSTS OUTPUT
#        pieb.sh keep root@HOST KNOWN_HOSTS OUTPUT DEADMAN
#        pieb.sh unkeep root@HOST KNOWN_HOSTS OUTPUT
# install unpacks ROOT.tar, a system's root, plain or compressed with xz,
# into /pie-b on the running system's volume. It installs PIEB-INIT, built
# from pieb-init.c, as /usr/appleinternal/sbin/launchd.pieb. A kernel
# booted with launchdsuffix=pieb then runs that system. It writes
# /pie-b/etc/pie-b-id, so reboot.sh can tell that system from the one
# around it. Install needs room for the archive, the unpacked tree and
# 1 GB to spare. remove takes all of it away. It refuses while the system
# runs from /pie-b, and while the boot partition still holds a trial.
# rootkey lets root log in to the system in /pie-b with KEY.pub, for tests
# only: it puts PermitRootLogin prohibit-password first in its
# sshd_config, and keeps the original and its sum as sshd_config.pie-test
# and sshd_config.pie-test.sum. It refuses if B's root has a .ssh
# directory. norootkey puts the original back and takes the key and the
# directory away. Both work from either system.
# keep makes the system in /pie-b the Pi's working system, from A. It adds
# a line to A's /etc/rc that starts keep/pie-b-return, and a line to B's
# /etc/rc that starts keep/pie-b-watch with DEADMAN, a darwin-arm64 build
# of deadman.c. It keeps both rc files and their sums as rc.pie-keep and
# rc.pie-keep.sum. In B it diverts blueberry-pie-os-update-boot to
# keep/update-boot-trial. keep needs a trial whose cmdline.txt has
# launchdsuffix=pieb, pieboot.fallback=1 and pie_watchdog_boot. unkeep
# undoes it from A: it stops a return that is waiting, takes the two rc
# lines out, and puts update-boot back. remove refuses while keep is in
# place.
ACTION=${1:-}
case $ACTION in
    install) [[ $# == 6 ]] || { sed -n '4,9p' "$0" >&2; exit 2; } ;;
    rootkey|keep) [[ $# == 5 ]] || { sed -n '4,9p' "$0" >&2; exit 2; } ;;
    remove|norootkey|unkeep) [[ $# == 4 ]] || { sed -n '4,9p' "$0" >&2; exit 2; } ;;
    *) sed -n '4,9p' "$0" >&2; exit 2 ;;
esac
HOST=$2 KNOWN=$3 OUT=$4
source "$(dirname -- "$0")/lib.sh"
SHIM=/usr/appleinternal/sbin/launchd.pieb
STAGED="/var/tmp/pie-b.tar /var/tmp/pie-b.tar.part /var/tmp/launchd.pieb /var/tmp/launchd.pieb.part"
not_pieb='if [ -f /etc/pie-b-id ] && [ ! -e /pie-b ]; then echo "running from /pie-b" >&2; exit 1; fi'
remove_all="rm -f $SHIM $STAGED
rm -rf /pie-b
rmdir /usr/appleinternal/sbin /usr/appleinternal 2>/dev/null || true
sync
for f in /pie-b $SHIM $STAGED; do [ ! -e \$f ] || { echo \"\$f is still there\" >&2; exit 1; }; done"
b_root='if [ -f /etc/pie-b-id ] && [ ! -e /pie-b ]; then R=
elif [ -f /pie-b/etc/pie-b-id ]; then R=/pie-b
else echo "no system in /pie-b" >&2; exit 1; fi
cfg=$R/private/etc/ssh/sshd_config
ssh=$R/private/var/root/.ssh'
if [[ $ACTION == rootkey ]]; then
    key=$(cat -- "$5")
    [[ $key == ssh-* && $key != *$'\n'* && $key != *\'* ]] || { say "FAIL: $5 is not one public key"; exit 1; }
    rrun "set -eu
$b_root
[ -f \$cfg ] && [ ! -e \$cfg.pie-test ] || { echo \"no \$cfg, or it is changed already\" >&2; exit 1; }
[ ! -e \$ssh ] || { echo \"\$ssh is there already\" >&2; exit 1; }
cp -p \$cfg \$cfg.pie-test
sum \$cfg.pie-test | cut -d' ' -f1 > \$cfg.pie-test.sum
{ echo 'PermitRootLogin prohibit-password'; cat \$cfg.pie-test; } > \$cfg.new
chown root:wheel \$cfg.new
chmod 644 \$cfg.new
mv \$cfg.new \$cfg
mkdir -p \$ssh
chown root:wheel \$ssh
chmod 700 \$ssh
echo '$key' > \$ssh/authorized_keys.new
chown root:wheel \$ssh/authorized_keys.new
chmod 600 \$ssh/authorized_keys.new
mv \$ssh/authorized_keys.new \$ssh/authorized_keys
sync
head -1 \$cfg" < /dev/null > "$OUT/rootkey.txt" 2>&1 || { say "FAIL: rootkey; see $OUT/rootkey.txt"; exit 1; }
    say "PASS: root may log in to the system in /pie-b with $5"
    exit 0
fi
if [[ $ACTION == norootkey ]]; then
    rrun "set -eu
$b_root
[ -f \$cfg.pie-test ] && [ -f \$cfg.pie-test.sum ] || { echo \"no \$cfg.pie-test\" >&2; exit 1; }
[ \"\$(sum \$cfg.pie-test | cut -d' ' -f1)\" = \"\$(cat \$cfg.pie-test.sum)\" ] || { echo \"\$cfg.pie-test is damaged\" >&2; exit 1; }
mv \$cfg.pie-test \$cfg
rm -f \$cfg.pie-test.sum \$ssh/authorized_keys
rmdir \$ssh
sync
[ ! -e \$ssh ]" < /dev/null > "$OUT/norootkey.txt" 2>&1 || { say "FAIL: norootkey; see $OUT/norootkey.txt"; exit 1; }
    say "PASS: the original sshd_config is back and root's key is gone"
    exit 0
fi
KEEP=$(cd -- "$(dirname -- "$0")/keep" && pwd)
RC_A=/private/etc/rc RC_B=/pie-b/private/etc/rc UB=/usr/libexec/blueberry-pie-os-update-boot
HOOK_A='if [ -x /usr/local/libexec/pie-b-return ]; then trap "" HUP; /usr/local/libexec/pie-b-return >> /var/log/pie-b-return.log 2>&1 < /dev/null & fi'
HOOK_B='if [ -x /usr/local/libexec/pie-b-watch ]; then trap "" HUP; /usr/local/libexec/pie-b-watch >> /var/log/pie-b-watch.log 2>&1 < /dev/null & fi'
devfs_chroot="mount -t devfs devfs /pie-b/dev
trap 'umount /pie-b/dev' EXIT"
if [[ $ACTION == keep ]]; then
    DM=$(realpath -- "$5")
    rsh "set -e
$not_pieb
[ -f /pie-b/private/etc/pie-b-id ] && [ -x $SHIM ] || { echo 'no system in /pie-b: run pieb.sh install first' >&2; exit 1; }
for f in $RC_A.pie-keep $RC_B.pie-keep /usr/local/libexec/pie-b-return /pie-b/usr/local/libexec/pie-b-watch; do
    [ ! -e \$f ] || { echo \"\$f is there already: keep is in place\" >&2; exit 1; }
done
[ -f $RC_A ] && [ -f $RC_B ] && [ -f /pie-b$UB ] && [ ! -e /pie-b$UB.pie-a ] || { echo 'unexpected rc or update-boot files' >&2; exit 1; }" < /dev/null ||
        { say "FAIL: not ready for keep; nothing changed"; exit 1; }
    rrun "set -eu
fat_mount rdonly
trap fat_umount EXIT
grep -qx 'os_prefix=trial/' \"\$FAT/config.txt\" || { echo 'config.txt does not boot trial/' >&2; exit 1; }
$(sed -n '/^cmdline_ok() {$/,/^}$/p' "$KEEP/pie-b-return")
cmdline_ok \"\$FAT/trial/cmdline.txt\" || { echo 'trial/cmdline.txt needs exactly one launchdsuffix=pieb, pieboot.fallback=1 and pie_watchdog_boot of 60 to 86400' >&2; exit 1; }" < /dev/null > "$OUT/keep-check.txt" 2>&1 ||
        { say "FAIL: the trial does not boot B with its way back; see $OUT/keep-check.txt; nothing changed"; exit 1; }
    for f in pie-b-return pie-b-watch update-boot-trial; do push "$KEEP/$f" "/var/tmp/$f" || exit 1; done
    push "$DM" /var/tmp/pie-b-deadman || exit 1
    rrun "set -eu
install -d -m 755 /usr/local/libexec /pie-b/usr/local/libexec /private/var/db
install -m 755 /var/tmp/pie-b-return /usr/local/libexec/pie-b-return
install -m 755 /var/tmp/pie-b-watch /pie-b/usr/local/libexec/pie-b-watch
install -m 755 /var/tmp/pie-b-deadman /pie-b/usr/local/libexec/deadman
printf '%s\n' '$HOOK_A' > /var/tmp/pie-keep-hook-a
printf '%s\n' '$HOOK_B' > /var/tmp/pie-keep-hook-b
for x in a b; do
    if [ \$x = a ]; then r=$RC_A; else r=$RC_B; fi
    cp -p \$r \$r.pie-keep
    sum \$r.pie-keep | cut -d' ' -f1 > \$r.pie-keep.sum
    cp -p \$r \$r.new
    [ -z \"\$(tail -c 1 \$r.new)\" ] || echo >> \$r.new
    cat /var/tmp/pie-keep-hook-\$x >> \$r.new
    sh -n \$r.new
    mv \$r.new \$r
done
rm -f /var/tmp/pie-keep-hook-a /var/tmp/pie-keep-hook-b
$devfs_chroot
chroot /pie-b dpkg-divert --local --rename --divert $UB.pie-a --add $UB
install -m 755 /var/tmp/update-boot-trial /pie-b$UB
rm -f /var/tmp/pie-b-return /var/tmp/pie-b-watch /var/tmp/update-boot-trial /var/tmp/pie-b-deadman
sync
tail -1 $RC_A
tail -1 $RC_B
chroot /pie-b dpkg-divert --list $UB" < /dev/null > "$OUT/keep.txt" 2>&1 ||
        { say "FAIL: keep; see $OUT/keep.txt, and run pieb.sh unkeep"; exit 1; }
    say "PASS: the system in /pie-b is kept; A returns to it 5 minutes after any boot of A"
    exit 0
fi
if [[ $ACTION == unkeep ]]; then
    rrun "set -eu
$not_pieb
pkill -f /usr/local/libexec/pie-b-return || true
printf '%s\n' '$HOOK_A' > /var/tmp/pie-keep-hook-a
printf '%s\n' '$HOOK_B' > /var/tmp/pie-keep-hook-b
for x in a b; do
    if [ \$x = a ]; then r=$RC_A; else r=$RC_B; fi
    if grep -qxF -f /var/tmp/pie-keep-hook-\$x \$r; then
        cp -p \$r \$r.new
        st=0
        grep -vxF -f /var/tmp/pie-keep-hook-\$x \$r > \$r.new || st=\$?
        [ \$st -le 1 ] || { echo \"filtering \$r failed\" >&2; rm -f \$r.new; exit 1; }
        [ \$((\$(wc -l < \$r) - 1)) = \$(wc -l < \$r.new) ] || { echo \"filtering \$r lost lines\" >&2; rm -f \$r.new; exit 1; }
        sh -n \$r.new
        mv \$r.new \$r
        sync
    fi
    if grep -q -e pie-b-return -e pie-b-watch \$r; then echo \"\$r still names pie-b-return or pie-b-watch\" >&2; exit 1; fi
    if [ -e \$r.pie-keep ] && ! cmp -s \$r \$r.pie-keep; then echo \"note: \$r differs from the copy keep made; only the hook was taken out\"; fi
    rm -f \$r.pie-keep \$r.pie-keep.sum
done
rm -f /var/tmp/pie-keep-hook-a /var/tmp/pie-keep-hook-b
$devfs_chroot
if [ -e /pie-b$UB.pie-a ]; then
    rm -f /pie-b$UB
    chroot /pie-b dpkg-divert --local --rename --remove $UB
else
    reg=\$(chroot /pie-b dpkg-divert --listpackage $UB) || { echo 'cannot read the diversions' >&2; exit 1; }
    if [ -n \"\$reg\" ]; then chroot /pie-b dpkg-divert --local --remove $UB; fi
fi
reg=\$(chroot /pie-b dpkg-divert --listpackage $UB) || { echo 'cannot read the diversions' >&2; exit 1; }
[ -z \"\$reg\" ] || { echo 'the diversion is still registered' >&2; exit 1; }
umount /pie-b/dev
trap - EXIT
[ -f /pie-b$UB ] && [ ! -e /pie-b$UB.pie-a ] || { echo 'B has no update-boot' >&2; exit 1; }
rm -f /usr/local/libexec/pie-b-return /var/db/pie-b-returns /var/db/pie-b-returns.new /var/db/pie-b-stay
rm -f /pie-b/usr/local/libexec/pie-b-watch /pie-b/usr/local/libexec/deadman /pie-b/private/var/db/pie-b-healthy
sync
echo unkept" < /dev/null > "$OUT/unkeep.txt" 2>&1 || { say "FAIL: unkeep; see $OUT/unkeep.txt. It can be run again."; exit 1; }
    say "PASS: keep is undone"
    exit 0
fi
if [[ $ACTION == remove ]]; then
    say "removing /pie-b and $SHIM"
    rrun "set -eu
$not_pieb
fat_mount rdonly
trap fat_umount EXIT
[ ! -e /private/etc/rc.pie-keep ] || { echo 'keep is in place: run pieb.sh unkeep first' >&2; exit 1; }
for f in tryboot.txt trial config-pie-orig.txt config.txt.new; do
    [ ! -e \"\$FAT/\$f\" ] || { echo \"the boot partition holds \$f: run trial.sh teardown first\" >&2; exit 1; }
done
fat_umount
trap - EXIT
$remove_all" < /dev/null > "$OUT/remove.txt" 2>&1 && { say "PASS: removed"; exit 0; }
    say "FAIL: remove; see $OUT/remove.txt"
    exit 1
fi
TAR=$(realpath -- "$5") INIT=$(realpath -- "$6")
rsh "[ ! -e /pie-b ] && [ ! -e $SHIM ] && [ ! -e /usr/appleinternal ]" < /dev/null ||
    { say "FAIL: /pie-b or /usr/appleinternal is already there; remove first"; exit 1; }
rrun "set -eu
$not_pieb" < /dev/null || { say "FAIL: the Pi is not running its own system"; exit 1; }
tree=$(python3 -I -c 'import sys, tarfile
t = 0
with tarfile.open(sys.argv[1]) as f:
    for m in f:
        t += (m.size + 4095) // 4096 * 4096 + 4096
print(t // 1024)' "$TAR") || { say "FAIL: cannot read $TAR"; exit 1; }
free=$(rsh "df -k / | awk 'NR == 2 {print \$4}'" < /dev/null)
need=$(( $(stat -c %s "$TAR") / 1024 + tree + $(stat -c %s "$INIT") / 1024 + 1048576 ))
[[ $free =~ ^[0-9]+$ ]] && ((free > need)) || { say "FAIL: $free KB free on /, $need KB needed"; exit 1; }
say "$free KB free on /, $need KB needed"
cleanup() {
    rsh "$remove_all" < /dev/null >> "$OUT/install.txt" 2>&1 ||
        say "cleanup failed: run pieb.sh remove"
}
say "pushing $TAR ($(stat -c %s "$TAR") bytes)"
push "$TAR" /var/tmp/pie-b.tar && push "$INIT" /var/tmp/launchd.pieb ||
    { say "FAIL: push"; cleanup; exit 1; }
id=$(sha256sum < "$TAR" | cut -d' ' -f1)
rsh "set -e
mkdir /pie-b
tar -C /pie-b -xpf /var/tmp/pie-b.tar
rm -f /var/tmp/pie-b.tar
[ -x /pie-b/sbin/launchd ] || { echo 'no /pie-b/sbin/launchd' >&2; exit 1; }
[ -d /pie-b/dev ] || { echo 'no /pie-b/dev' >&2; exit 1; }
[ \"\$(readlink /pie-b/etc)\" = private/etc ] || { echo '/pie-b/etc is not a link to private/etc' >&2; exit 1; }
[ -d /pie-b/private/etc ] && [ ! -L /pie-b/private/etc ] || { echo '/pie-b/private/etc is not a directory' >&2; exit 1; }
echo $id > /pie-b/private/etc/pie-b-id
mkdir -p /usr/appleinternal/sbin
chown root:wheel /var/tmp/launchd.pieb
chmod 755 /var/tmp/launchd.pieb
mv /var/tmp/launchd.pieb $SHIM
sync
du -sk /pie-b" < /dev/null > "$OUT/install.txt" 2>&1 ||
    { say "FAIL: unpacking; see $OUT/install.txt"; cleanup; exit 1; }
say "PASS: /pie-b holds $(tail -1 "$OUT/install.txt" | cut -f1) KB, $SHIM installed"
