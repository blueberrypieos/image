#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: trial.sh setup root@HOST KNOWN_HOSTS OUTPUT BACKUP TRIAL DTB [flag] [nodeadline]
#        trial.sh teardown|status root@HOST KNOWN_HOSTS OUTPUT BACKUP
# setup puts TRIAL's files in the boot partition's trial/, the old
# config.txt in tryboot.txt and in config-pie-orig.txt, and a last [all]
# section in config.txt that boots trial/pieboot.bin, trial/xnu.bundle and
# trial/cmdline.txt. TRIAL needs pieboot.bin with the fallback boot,
# xnu.bundle, and a one-line cmdline.txt with pieboot.fallback=1, or
# pieboot.fallback=flag with the flag argument, and pie.slot=trial. With
# pieboot.fallback=1 it also needs pie_watchdog_boot=N, unless the
# nodeadline argument says the trial's kernel has none. DTB is the board's
# device tree. The device trees and overlays TRIAL lacks come from BACKUP.
# teardown puts the boot partition back as BACKUP has it. status exits 0
# if the boot partition is as BACKUP has it, else 1.
ACTION=${1:-}
case $ACTION in
    setup) [[ $# -ge 7 && $# -le 9 ]] || { sed -n '4,5p' "$0" >&2; exit 2; } ;;
    teardown|status) [[ $# == 5 ]] || { sed -n '4,5p' "$0" >&2; exit 2; } ;;
    *) sed -n '4,5p' "$0" >&2; exit 2 ;;
esac
HOST=$2 KNOWN=$3 OUT=$4
BACKUP=$(realpath -- "$5")
source "$(dirname -- "$0")/lib.sh"
[[ -s $BACKUP/fat/config.txt && -s $BACKUP/fat-sums.txt ]] || { echo "$BACKUP is not a backup.sh output." >&2; exit 2; }
(cd "$BACKUP" && sha256sum -c --quiet SHA256SUMS) || { echo "$BACKUP fails its SHA256SUMS." >&2; exit 2; }
(cd "$BACKUP/fat" && find . -type f -exec sha256sum {} + | sort -k 2) > "$OUT/backup-fat-check.txt"
cmp -s "$OUT/backup-fat-check.txt" "$BACKUP/fat-sums.txt" || { echo "$BACKUP/fat differs from its fat-sums.txt." >&2; exit 2; }
CONFIG_SUM=$(awk '$2 == "./config.txt" {print $1}' "$BACKUP/fat-sums.txt")
trial_config() {
    cat "$BACKUP/fat/config.txt"
    printf '\n[all]\nos_prefix=trial/\nkernel=pieboot.bin\ninitramfs xnu.bundle followkernel\ncmdline=cmdline.txt\n'
}
NEW_SUM=$(trial_config | sha256sum | cut -d' ' -f1)

remote_sums() {
    rrun 'set -eu
fat_mount rdonly
trap fat_umount EXIT
fat_sums' < /dev/null
}

if [[ $ACTION == status ]]; then
    rsh 'sysctl -n kern.bootargs' < /dev/null | tee "$OUT/bootargs.txt"
    remote_sums > "$OUT/fat-sums-now.txt" || { say "FAIL: cannot read the boot partition"; exit 1; }
    if diff -u "$BACKUP/fat-sums.txt" "$OUT/fat-sums-now.txt" > "$OUT/fat-status.diff"; then
        say "the boot partition is as in $BACKUP"
        exit 0
    fi
    say "the boot partition differs from $BACKUP:"
    grep '^[-+][^-+]' "$OUT/fat-status.diff" >&2 || true
    exit 1
fi

if [[ $ACTION == teardown ]]; then
    say "teardown: config.txt back first, then tryboot.txt, trial/ and the rescue copy go"
    rc=0
    rrun "set -eu
fat_lock
trap fat_unlock EXIT
fat_mount rw
good() { [ -f \"\$1\" ] && [ \"\$(sum \"\$1\" | cut -d' ' -f1)\" = $CONFIG_SUM ]; }
cleanup() {
	rc=\$?
	set +e
	if good \"\$FAT/config.txt\"; then rm -f \"\$FAT/config.txt.new\" || rc=1; fi
	fat_umount || rc=1
	fat_unlock
	exit \$rc
}
trap cleanup EXIT
if [ -e /private/etc/rc.pie-keep ] && [ ! -e /var/db/pie-b-stay ]; then
	echo 'keep is in place: create /var/db/pie-b-stay first, so that A does not return to B during the teardown' >&2
	exit 1
fi
if [ -e \"\$FAT/config.txt\" ] && [ '${PI_FORCE_TEARDOWN:-}' != 1 ]; then
	now=\$(sum \"\$FAT/config.txt\" | cut -d' ' -f1)
	if [ \"\$now\" != $CONFIG_SUM ] && [ \"\$now\" != $NEW_SUM ]; then
		echo 'config.txt is neither the backup copy nor the trial config: changed since the backup? PI_FORCE_TEARDOWN=1 restores the backup copy anyway' >&2
		exit 1
	fi
fi
cat > \"\$FAT/config.txt.new\"
sync
good \"\$FAT/config.txt.new\"
if ! good \"\$FAT/config-pie-orig.txt\"; then
	rm -f \"\$FAT/config-pie-orig.txt\"
	cp \"\$FAT/config.txt.new\" \"\$FAT/config-pie-orig.txt\"
	sync
	good \"\$FAT/config-pie-orig.txt\"
fi
if ! mv \"\$FAT/config.txt.new\" \"\$FAT/config.txt\" || ! good \"\$FAT/config.txt\"; then
	cp \"\$FAT/config-pie-orig.txt\" \"\$FAT/config.txt\"
	sync
	good \"\$FAT/config.txt\"
	exit 1
fi
sync
rm -f \"\$FAT/tryboot.txt\"
rm -rf \"\$FAT/trial\" \"\$FAT/pie-stage\"
rm -f \"\$FAT/config-pie-orig.txt\"
sync
echo teardown-done" < "$BACKUP/fat/config.txt" > "$OUT/teardown.txt" 2>&1 || rc=$?
    remote_sums > "$OUT/fat-sums-after.txt" || { say "FAIL: cannot read the boot partition after teardown"; exit 1; }
    if ((rc == 0)) && grep -q teardown-done "$OUT/teardown.txt" &&
        diff -u "$BACKUP/fat-sums.txt" "$OUT/fat-sums-after.txt" > "$OUT/teardown.diff"; then
        say "PASS: the boot partition matches $BACKUP"
        exit 0
    fi
    diff -u "$BACKUP/fat-sums.txt" "$OUT/fat-sums-after.txt" > "$OUT/teardown.diff" || true
    say "FAIL: teardown rc $rc; see $OUT/teardown.txt and $OUT/teardown.diff"
    exit 1
fi

TRIAL=$(realpath -- "$6")
DTB=$7
MODE=1 DEADLINE=1
for o in "${@:8}"; do
    case $o in
        flag) MODE=flag ;;
        nodeadline) DEADLINE=0 ;;
        *) sed -n '4,5p' "$0" >&2; exit 2 ;;
    esac
done
[[ $DTB =~ ^[a-z0-9-]+\.dtb$ ]] || { echo "Bad device tree name: $DTB" >&2; exit 2; }
for f in pieboot.bin xnu.bundle cmdline.txt; do
    [[ -s $TRIAL/$f ]] || { echo "$TRIAL has no $f." >&2; exit 2; }
done
lines=$(grep -c '' "$TRIAL/cmdline.txt")
[[ $lines == 1 ]] || { echo 'cmdline.txt must be one line.' >&2; exit 2; }
read -r -a args < "$TRIAL/cmdline.txt"
nfb=0 nslot=0 nbd=0 suffix=
for a in "${args[@]}"; do
    case $a in
        pieboot.fallback=*) nfb=$((nfb + 1)); fb=${a#*=} ;;
        pie.slot=*) nslot=$((nslot + 1)); slot=${a#*=} ;;
        pie_watchdog_boot=*) nbd=$((nbd + 1)); bd=${a#*=} ;;
        launchdsuffix=*) suffix=${a#*=} ;;
    esac
done
[[ $nfb == 1 && $fb == "$MODE" ]] || { echo "cmdline.txt needs exactly one pieboot.fallback=$MODE." >&2; exit 2; }
[[ $nslot == 1 && $slot == trial ]] || { echo 'cmdline.txt needs exactly one pie.slot=trial.' >&2; exit 2; }
if [[ $MODE == 1 && $DEADLINE == 0 && ${PI_ALLOW_NODEADLINE:-} != 1 ]]; then
    echo 'nodeadline with pieboot.fallback=1: a hang after the kernel takes the watchdog over has no way back. Set PI_ALLOW_NODEADLINE=1 to go on.' >&2
    exit 2
fi
if [[ $MODE == 1 && $DEADLINE == 1 ]]; then
    [[ $nbd == 1 && $bd =~ ^[0-9]+$ ]] && ((10#$bd >= 60 && 10#$bd <= 86400)) ||
        { echo 'cmdline.txt needs one pie_watchdog_boot=N, 60 to 86400, or the nodeadline argument.' >&2; exit 2; }
fi
grep -aq 'pieboot.fallback=' "$TRIAL/pieboot.bin" || { echo "$TRIAL/pieboot.bin has no fallback boot." >&2; exit 2; }
for cfg in "$BACKUP/fat/config.txt" "$BACKUP/fat/usercfg.txt"; do
    [[ -e $cfg ]] || continue
    if grep -Eiq '^[[:space:]]*(os_prefix|overlay_prefix|cmdline|boot_partition|device_tree)' "$cfg" ||
        grep -Eiq 'tryboot' "$cfg" ||
        grep -Eiq '^[[:space:]]*(kernel|initramfs|start_file|fixup_file)[[:space:]=]+/' "$cfg" ||
        grep -Ei '^[[:space:]]*include' "$cfg" | grep -Eviq '^[[:space:]]*include[[:space:]]+usercfg\.txt[[:space:]]*$'; then
        echo "${cfg##*/} has a setting this script does not handle." >&2
        exit 2
    fi
done
grep -Eq ' \./autoboot\.txt$' "$BACKUP/fat-sums.txt" && { echo 'The boot partition has an autoboot.txt.' >&2; exit 2; }

STAGE=$OUT/stage
[[ ! -e $STAGE ]] || { echo "Use a new OUTPUT: $STAGE exists." >&2; exit 2; }
mkdir -p "$STAGE/trial"
cp -a -- "$TRIAL"/. "$STAGE/trial/"
for dtb in "$BACKUP"/fat/*.dtb; do
    [[ -e $STAGE/trial/${dtb##*/} ]] || cp -- "$dtb" "$STAGE/trial/"
done
[[ -s $STAGE/trial/$DTB ]] || { echo "No $DTB for the trial." >&2; exit 2; }
if [[ -d $BACKUP/fat/overlays ]]; then
    mkdir -p "$STAGE/trial/overlays"
    cp -a --update=none -- "$BACKUP/fat/overlays"/. "$STAGE/trial/overlays/"
fi
if [[ -d $TRIAL/overlays ]]; then
    [[ -s $STAGE/trial/overlays/README ]] || { echo "$TRIAL/overlays has no README; the firmware would ignore it." >&2; exit 2; }
fi
cp -- "$BACKUP/fat/config.txt" "$STAGE/tryboot.txt"
[[ $(sha256sum < "$STAGE/tryboot.txt" | cut -d' ' -f1) == "$CONFIG_SUM" ]] || { echo 'tryboot.txt would not be the old config.txt.' >&2; exit 2; }
trial_config > "$STAGE/config.txt"
(cd "$STAGE" && find . -type f ! -name SUMS -exec sha256sum {} + | sort -k 2 > SUMS)
{ grep -v ' \./config\.txt$' "$BACKUP/fat-sums.txt"
  grep -v -e ' \./SUMS$' "$STAGE/SUMS"
  printf '%s  ./config-pie-orig.txt\n' "$CONFIG_SUM"; } | sort -k 2 > "$OUT/fat-sums-expected.txt"

if [[ -n $suffix ]]; then
    [[ $suffix =~ ^[a-z0-9]+$ ]] || { echo "Bad launchdsuffix: $suffix" >&2; exit 2; }
    rsh "set -e
[ -x /usr/appleinternal/sbin/launchd.$suffix ] || { echo 'no /usr/appleinternal/sbin/launchd.$suffix: run pieb.sh install first' >&2; exit 1; }
[ -x /pie-b/sbin/launchd ] || { echo 'no /pie-b/sbin/launchd' >&2; exit 1; }
[ -f /pie-b/etc/pie-b-id ] || { echo 'no /pie-b/etc/pie-b-id' >&2; exit 1; }" < /dev/null ||
        { say "FAIL: launchdsuffix=$suffix, but the Pi is not ready for it; nothing changed"; exit 1; }
fi
remote_sums > "$OUT/fat-sums-before.txt" || { say "FAIL: cannot read the boot partition"; exit 1; }
diff -u "$BACKUP/fat-sums.txt" "$OUT/fat-sums-before.txt" > "$OUT/preflight.diff" || {
    say "FAIL: the boot partition is not as in $BACKUP; nothing changed"; exit 1; }
say "setup: $(grep -c ' ./trial/' "$STAGE/SUMS") files in trial/, mode pieboot.fallback=$MODE, device tree $DTB"
diff -u "$BACKUP/fat/config.txt" "$STAGE/config.txt" | tee "$OUT/config.diff" >&2 || true

rc=0
tar -C "$STAGE" -cf - . | rrun "set -eu
fat_lock
trap fat_unlock EXIT
fat_mount rw
staged=
restore() {
	if [ -f \"\$FAT/config-pie-orig.txt\" ] && [ \"\$(sum \"\$FAT/config-pie-orig.txt\" | cut -d' ' -f1)\" = $CONFIG_SUM ]; then
		cp \"\$FAT/config-pie-orig.txt\" \"\$FAT/config.txt\"
		sync
	fi
}
cleanup() {
	rc=\$?
	set +e
	now=\$(sum \"\$FAT/config.txt\" 2>/dev/null | cut -d' ' -f1)
	if [ \"\$now\" != $CONFIG_SUM ] && [ \"\$now\" != $NEW_SUM ]; then restore || rc=1; fi
	if [ -n \"\$staged\" ]; then rm -rf \"\$FAT/pie-stage\" || rc=1; fi
	fat_umount || rc=1
	fat_unlock
	exit \$rc
}
trap cleanup EXIT
[ \"\$(sum \"\$FAT/config.txt\" | cut -d' ' -f1)\" = $CONFIG_SUM ] || { echo 'config.txt is not the backup copy' >&2; exit 1; }
for p in tryboot.txt trial pie-stage config-pie-orig.txt config.txt.new autoboot.txt; do
	[ ! -e \"\$FAT/\$p\" ] || { echo \"\$p is already there\" >&2; exit 1; }
done
mkdir \"\$FAT/pie-stage\"
staged=1
tar -C \"\$FAT/pie-stage\" -xf -
cd \"\$FAT/pie-stage\"
sum -c SUMS > /dev/null
cd /
cp \"\$FAT/config.txt\" \"\$FAT/config-pie-orig.txt\"
sync
[ \"\$(sum \"\$FAT/config-pie-orig.txt\" | cut -d' ' -f1)\" = $CONFIG_SUM ]
mv \"\$FAT/pie-stage/trial\" \"\$FAT/trial\"
mv \"\$FAT/pie-stage/tryboot.txt\" \"\$FAT/tryboot.txt\"
sync
mv \"\$FAT/pie-stage/config.txt\" \"\$FAT/config.txt\" || { restore; exit 1; }
sync
[ \"\$(sum \"\$FAT/config.txt\" | cut -d' ' -f1)\" = $NEW_SUM ] || { restore; exit 1; }
echo setup-done" > "$OUT/setup.txt" 2>&1 || rc=$?
remote_sums > "$OUT/fat-sums-after.txt" || { say "FAIL: cannot read the boot partition after setup. Do not reboot."; exit 1; }
if ((rc == 0)) && grep -q setup-done "$OUT/setup.txt" &&
    diff -u "$OUT/fat-sums-expected.txt" "$OUT/fat-sums-after.txt" > "$OUT/setup.diff"; then
    say "PASS: the boot partition holds exactly the trial setup"
    exit 0
fi
diff -u "$OUT/fat-sums-expected.txt" "$OUT/fat-sums-after.txt" > "$OUT/setup.diff" || true
say "FAIL: setup rc $rc; see $OUT/setup.txt and $OUT/setup.diff. Run teardown before any reboot."
exit 1
