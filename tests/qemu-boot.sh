#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: qemu-boot.sh IMAGE MANIFEST QEMU SSH_PORT OUTPUT
set -euo pipefail
[[ $# == 5 ]] || { sed -n '4p' "$0" >&2; exit 2; }
IMAGE=$(realpath -- "$1")
MANIFEST=$(realpath -- "$2")
QEMU=$(realpath -- "$3")
PORT=$4 OUT=$5
[[ $PORT =~ ^[0-9]+$ ]] && ((PORT > 1023 && PORT < 65536)) || exit 2
source "$(dirname -- "$0")/common.sh"
prepare
sha256sum "$IMAGE" > "$OUT/image-sha256.txt"
if [[ -n ${IMAGE_SHA256:-} ]]; then
    printf '%s  %s\n' "$IMAGE_SHA256" "$IMAGE" | sha256sum -c - >> "$OUT/image-sha256.txt" || exit 1
fi
case "$IMAGE" in
    *.xz) xz -dc -- "$IMAGE" > "$OUT/sd.img" ;;
    *) cp --sparse=always -- "$IMAGE" "$OUT/sd.img" ;;
esac
size=$(stat -c %s "$OUT/sd.img")
card=1048576
while ((card < size)); do card=$((card * 2)); done
truncate -s "$card" "$OUT/sd.img"
head -c $((32768 * 512)) "$OUT/sd.img" > "$OUT/first16m-before.bin"
case $(od -An -tx1 -j 466 -N 1 "$OUT/sd.img" | tr -d ' ') in
    bf) ROOT_ZFS=1 ;;
    af) ROOT_ZFS=0 ;;
    *) echo 'Partition 2 is neither HFS+ nor ZFS.' >&2; exit 2 ;;
esac
OFFSET=$(python3 - "$OUT/sd.img" <<'PY'
import struct
import sys
with open(sys.argv[1], 'rb') as f:
    mbr = f.read(512)
assert mbr[510:] == b'\x55\xaa'
assert mbr[450] in (0xb, 0xc)
print(struct.unpack_from('<I', mbr, 454)[0] * 512)
PY
)
mkdir "$OUT/fat"
for name in pieboot.bin bcm2711-rpi-4-b.dtb xnu.bundle cmdline.txt; do
    mcopy -i "$OUT/sd.img@@$OFFSET" "::/$name" "$OUT/fat/$name"
done
sha256sum "$OUT"/fat/* > "$OUT/boot-hashes.txt"
compare_bundle
ARGS="$(cat "$OUT/fat/cmdline.txt") -v ml-timeout-ticket-lock-scale=20 ml-timeout-lock-scale=20"
CMD=("$QEMU" -pidfile "$OUT/qemu.pid" -nographic -no-reboot -M raspi4b -m 2G -cpu cortex-a72
    -dtb "$OUT/fat/bcm2711-rpi-4-b.dtb" -drive "if=sd,index=1,format=raw,cache=unsafe,file=$OUT/sd.img"
    -nic "user,model=bcm2838-genet,hostfwd=tcp:127.0.0.1:$PORT-:22"
    -kernel "$OUT/fat/pieboot.bin" -initrd "$OUT/fat/xnu.bundle" -append "$ARGS")
printf '%q ' "${CMD[@]}" > "$OUT/qemu-command.txt"
printf '\n' >> "$OUT/qemu-command.txt"
mkfifo "$OUT/console.in"
exec 3<> "$OUT/console.in"
boot() {
    "${CMD[@]}" < "$OUT/console.in" > "$1" 2>&1 &
    QP=$!
}
boot "$OUT/console.log"
stop() {
    if kill -0 "$QP" 2>/dev/null; then
        kill -TERM "$QP" 2>/dev/null || true
        for ((n=0;n<50;n++)); do kill -0 "$QP" 2>/dev/null || break; sleep .1; done
        if kill -0 "$QP" 2>/dev/null; then kill -KILL "$QP" 2>/dev/null || true; fi
    fi
    wait "$QP" 2>/dev/null || true
    printf 'QEMU PID %s stopped\n' "$QP" > "$OUT/stopped.txt"
}
trap stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$OUT/askpass" <<'SH'
#!/bin/sh
printf '%s\n' "$PIE_PASSWORD"
SH
chmod 700 "$OUT/askpass"
export SSH_ASKPASS=$OUT/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=:0
export PIE_PASSWORD=${PIE_PASSWORD:-blueberry}
export PIE_OLD_PASSWORD=$PIE_PASSWORD
export PIE_NEW_PASSWORD=${PIE_NEW_PASSWORD:-blueberry-test}
export ANN_PASSWORD=${ANN_PASSWORD:-ann-test}
[[ $PIE_NEW_PASSWORD != "$PIE_PASSWORD" ]] || { echo 'PIE_NEW_PASSWORD must differ from PIE_PASSWORD.' >&2; exit 2; }
SSH_OPTS=(ssh -F /dev/null -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$OUT/known_hosts"
    -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1 -p "$PORT")
SSH=("${SSH_OPTS[@]}" pie@127.0.0.1)
TTY_SSH=("${SSH_OPTS[@]}" -tt pie@127.0.0.1)
ANN_SSH=("${SSH_OPTS[@]}" ann@127.0.0.1)
ADMIN_SSH=("${SSH[@]}")
wait_up() {
    UP=0
    for ((n=0;n<240;n++)); do
        if remote true > "$OUT/ssh-probe$2.txt" 2>&1; then UP=1; break; fi
        if ! kill -0 "$QP" 2>/dev/null || grep -aqF 'panic(cpu' "$1"; then break; fi
        sleep 2
    done
}
prompts() { python3 "$HERE/dialog.py" "$@"; }
as_old() { ( export PIE_PASSWORD=$PIE_OLD_PASSWORD; "$@" ); }
as_ann() { ( export PIE_PASSWORD=$ANN_PASSWORD; "$@" ); }
ssh_refused() {
    local out
    if out=$(as_old remote 'id -un' 2>&1); then printf '%s\n' "$out"; return 1; fi
    printf '%s\n' "$out"
    grep -q 'Permission denied' <<< "$out"
}
sudo_refused() {
    local out
    if out=$(printf '%s\n' "$PIE_OLD_PASSWORD" | "${ADMIN_SSH[@]}" "sudo -k -S -p '' id -u" 2>&1); then
        printf '%s\n' "$out"
        return 1
    fi
    printf '%s\n' "$out"
    grep -q 'incorrect password attempt' <<< "$out"
}
chkpasswd_new() {
    local out
    if ! out=$(prompts -- "${TTY_SSH[@]}" /usr/libexec/chkpasswd <<'STEPS'
expect (?i)password:
secret PIE_PASSWORD
status 0
STEPS
    ); then
        printf '%s\n' "$out"
        return 1
    fi
    printf '%s\n' "$out"
    ! grep -q Sorry <<< "$out"
}
sudo_id() {
    local out
    out=$(privileged 'id -u' < /dev/null)
    printf '%s\n' "$out"
    [[ $out == 0 ]]
}
ann_ssh() {
    local out
    out=$(as_ann "${ANN_SSH[@]}" 'id -un' < /dev/null)
    printf '%s\n' "$out"
    [[ $out == ann ]]
}
ann_sudo() {
    local out
    out=$(printf '%s\n' "$ANN_PASSWORD" | as_ann "${ANN_SSH[@]}" "sudo -k -S -p '' -l" 2>&1)
    printf '%s\n' "$out"
    grep -q '(ALL) ALL' <<< "$out"
}
console_login() {
    prompts --log "$1" --input "$OUT/console.in" <<'STEPS'
send
expect login:
send pie
expect (?i)password:
secret PIE_OLD_PASSWORD
expect Login incorrect
expect login:
send pie
expect (?i)password:
secret PIE_PASSWORD
expect \$\s
send printf 'CONSOLE-%s-%s\n' "$(id -un)" "$(id -u)"
expect CONSOLE-pie-501
send exit
expect login:
STEPS
}
accounts_unique() {
    local dups name
    dups=$(sort "$1" | uniq -d)
    if [[ -n $dups ]]; then printf 'Listed twice: %s\n' "$dups"; return 1; fi
    for name in 'user root' 'user pie' 'user ann' 'group wheel' 'group admin'; do
        grep -qxF "$name" "$1" || { printf 'Missing: %s\n' "$name"; return 1; }
    done
    echo 'Each name once.'
}
account_state() {
    local s=$1
    check "od-running$s" remote 'pgrep -x opendirectoryd'
    check "od-store$s" privileged_input 'sh -s' <<'SH'
set -eu
n=/var/db/dslocal/nodes/Default
for d in /var/db/dslocal /var/db/dslocal/nodes $n $n/users $n/groups; do
    stat -f '%Sp %Su:%Sg %N' "$d"
    [ "$(stat -f '%Lp %u' "$d")" = "700 0" ]
done
for f in $n/users/* $n/groups/*; do
    stat -f '%Sp %Su:%Sg %N' "$f"
    [ "$(stat -f '%Lp %u' "$f")" = "600 0" ]
done
if ls -A $n/users $n/groups | grep '^\.'; then
    echo 'Dot files remain.'
    exit 1
fi
SH
    check "od-read-pie$s" remote 'sh -s' <<'SH'
set -eu
r=$(dscl . -read /Users/pie)
printf '%s\n' "$r"
for l in 'RecordName: pie' 'UniqueID: 501' 'PrimaryGroupID: 20' 'NFSHomeDirectory: /Users/pie' \
    'UserShell: /bin/sh' 'RealName: Pie' 'Password: ********' \
    'AuthenticationAuthority: ;ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>'; do
    printf '%s\n' "$r" | grep -qxF -- "$l" || { echo "Missing: $l"; exit 1; }
done
printf '%s\n' "$r" | grep -qE '^GeneratedUID: [0-9A-F-]{36}$' || { echo 'Missing: GeneratedUID'; exit 1; }
if printf '%s\n' "$r" | grep -q ShadowHashData; then echo 'ShadowHashData is shown.'; exit 1; fi
SH
    check "od-shadow-hidden$s" remote 'sh -s' <<'SH'
out=$(dscl . -read /Users/pie ShadowHashData 2>&1) && { echo 'Read as pie.'; exit 1; }
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q 'No such key'
SH
    check "od-shadow-root$s" privileged_input 'sh -s' <<'SH'
set -eu
out=$(dscl . -read /Users/pie ShadowHashData)
case "$out" in
ShadowHashData:* | dsAttrTypeNative:ShadowHashData:*) echo "ShadowHashData: present, ${#out} characters" ;;
*) echo 'No ShadowHashData.'; exit 1 ;;
esac
SH
    check "od-writes-refused$s" remote 'sh -s' <<'SH'
fail=0
refused() {
    e=$1
    shift
    if out=$("$@" 2>&1); then echo "Accepted: $*"; fail=1; return; fi
    printf '%s\n' "$out"
    case "$out" in *"(error $e)"*) ;; *) echo "Not error $e: $*"; fail=1 ;; esac
}
refused 4001 dscl . -create /Users/x
refused 4001 dscl . -create /Users/pie UniqueID 0
refused 4001 dscl . -delete /Groups/admin
refused 5101 dscl . -passwd /Users/root x
if dscl . -read /Users/x RecordName > /dev/null 2>&1; then echo '/Users/x exists.'; fail=1; fi
dscl . -read /Users/pie UniqueID | grep -qx 'UniqueID: 501' || fail=1
dscl . -read /Groups/admin RecordName | grep -qx 'RecordName: admin' || fail=1
exit "$fail"
SH
    check "id-groups$s" remote 'sh -s' <<'SH'
set -eu
id pie
groups pie
groups
id pie | grep -q '^uid=501(pie) gid=20(staff) '
id pie | grep -q '80(admin)'
groups pie | tr ' ' '\n' | grep -qx admin
groups | tr ' ' '\n' | grep -qx admin
[ "$(id -Gn | cut -d ' ' -f 1)" = staff ]
SH
    check "ls-owners$s" remote 'sh -s' <<'SH'
set -eu
ls -ld /Users/pie /var/root
ls -ld /Users/pie | awk '{ exit !($3 == "pie" && $4 == "staff") }'
ls -ld /var/root | awk '{ exit !($3 == "root") }'
SH
    if [[ -n ${LIST_ACCOUNTS:-} ]]; then
        if remote 'cat > /tmp/list-accounts && chmod 755 /tmp/list-accounts' < "$LIST_ACCOUNTS"; then
            check "list-accounts$s" remote /tmp/list-accounts
            check "accounts-unique$s" accounts_unique "$OUT/list-accounts$s.txt"
            remote 'rm -f /tmp/list-accounts' < /dev/null || true
        else
            record FAIL "list-accounts$s"
        fi
    else
        echo 'BLOCKED: set LIST_ACCOUNTS to a darwin-arm64 build of tests/list-accounts.c.' > "$OUT/accounts-unique$s.txt"
        record BLOCKED "accounts-unique$s"
    fi
}
password_checks() {
    local s=$1 log=$2
    check "ssh-old-refused$s" ssh_refused
    check "ssh-new$s" remote 'test "$(id -un)" = pie'
    check "sudo-old-refused$s" sudo_refused
    check "sudo-new$s" sudo_id
    check "chkpasswd-old-refused$s" prompts -- "${TTY_SSH[@]}" /usr/libexec/chkpasswd <<'STEPS'
expect (?i)password:
secret PIE_OLD_PASSWORD
expect Sorry
STEPS
    check "chkpasswd-new$s" chkpasswd_new
    check "console-login$s" console_login "$log"
}
ann_checks() {
    local s=$1
    check "ann-id$s" remote 'sh -s' <<'SH'
set -eu
id ann
id ann | grep -q '^uid=502(ann) gid=20(staff) '
id ann | grep -q '80(admin)'
dscl . -read /Users/ann GeneratedUID UniqueID
dscl . -read /Users/ann GeneratedUID | grep -qE '^GeneratedUID: [0-9A-F-]{36}$'
SH
    check "ann-ssh$s" ann_ssh
    check "ann-sudo$s" ann_sudo
    check "ann-ls$s" privileged_input 'sh -s' <<'SH'
set -eu
f=$(mktemp /tmp/owner.XXXXXX)
trap 'rm -f "$f"' EXIT
chown 502 "$f"
ls -l "$f" /Users/ann
ls -l "$f" | awk '{ exit !($3 == "ann") }'
ls -ld /Users/ann | awk '{ exit !($3 == "ann" && $4 == "staff") }'
rm -f "$f"
SH
}
accounts() {
    check passwd-old-refused prompts -- "${TTY_SSH[@]}" passwd <<'STEPS'
expect (?i)password:
secret PIE_NEW_PASSWORD
expect (?i)password:
secret PIE_NEW_PASSWORD
expect (?i)password:
secret PIE_NEW_PASSWORD
expect passwd: authentication token failure
STEPS
    if prompts -- "${TTY_SSH[@]}" passwd > "$OUT/passwd-change.txt" 2>&1 <<'STEPS'
expect (?i)password:
secret PIE_PASSWORD
expect (?i)password:
secret PIE_NEW_PASSWORD
expect (?i)password:
secret PIE_NEW_PASSWORD
status 0
STEPS
    then
        record PASS passwd-change
        export PIE_PASSWORD=$PIE_NEW_PASSWORD
        password_checks '' "$OUT/console.log"
    else
        record FAIL passwd-change
    fi
    check ann-create privileged_input 'sh -s' <<'SH'
set -eu
dscl . -create /Users/ann
dscl . -create /Users/ann UniqueID 502
dscl . -create /Users/ann PrimaryGroupID 20
dscl . -create /Users/ann NFSHomeDirectory /Users/ann
dscl . -create /Users/ann UserShell /bin/sh
dscl . -create /Users/ann RealName "Ann Example"
dscl . -append /Groups/admin GroupMembership ann
install -d -m 755 -o ann -g staff /Users/ann
SH
    check ann-passwd privileged_input 'passwd ann' < <(printf '%s\n%s\n' "$ANN_PASSWORD" "$ANN_PASSWORD")
    ann_checks ''
    account_state ''
}
reboot_guest() {
    timeout 60 "${ADMIN_SSH[@]}" "sudo -k -S -p '' sh -c 'sync; shutdown -r now'" \
        < <(printf '%s\n' "$PIE_PASSWORD") > "$OUT/reboot.txt" 2>&1 || true
    for ((n=0;n<120;n++)); do kill -0 "$QP" 2>/dev/null || break; sleep 1; done
    if kill -0 "$QP" 2>/dev/null; then record FAIL reboot; return 1; fi
    wait "$QP" 2>/dev/null || true
    record PASS reboot
    boot "$OUT/console-reboot.log"
    wait_up "$OUT/console-reboot.log" -reboot
    if ((UP)); then record PASS ssh-after-reboot; else record FAIL ssh-after-reboot; return 1; fi
    account_state -after-reboot
    password_checks -after-reboot "$OUT/console-reboot.log"
    ann_checks -after-reboot
}
loader_skips() {
    local out
    out=$(privileged /usr/sbin/pie-update-loader 2>&1) || { printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out"
    grep -q ' is not a board this loader is for; nothing written$' <<< "$out"
}
wifi_idle() {
    local out
    out=$(privileged "pgrep -U 0 -xf 'pie-wifi watch' && pie-wifi list && echo listed" 2>&1) || { printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out"
    grep -qx listed <<< "$out"
}
zfs_settings() {
    privileged_input "sh -s -- $ROOT_ZFS" <<'SH'
set -u
d=/etc/dpkg/dpkg.cfg.d a=/etc/apt/apt.conf.d c=/usr/lib/blueberry-pie-os/zfs
if mount | awk '$2 == "on" && $3 == "/" && $4 == "(zfs," { f = 1 } END { exit !f }'; then zfs=1; else zfs=0; fi
[ "$zfs" = "$1" ] || { echo "The guest's root is not the image's kind."; exit 1; }
if [ "$zfs" = 1 ]; then
    echo 'The root is a ZFS dataset.'
    cmp "$c/dpkg.cfg" "$d/pie-zfs" && cmp "$c/apt.conf" "$a/40pie-zfs" && test -L /private/var/lib/dpkg || exit 1
else
    echo 'The root is not a ZFS dataset.'
    ls -ld /private/var/lib/dpkg
    test -d /private/var/lib/dpkg && test ! -L /private/var/lib/dpkg || exit 1
    for f in "$d/pie-zfs" "$d/pie-data" "$a/40pie-zfs"; do
        if [ -e "$f" ]; then echo "$f exists."; exit 1; fi
    done
fi
echo 'dpkg and apt have the settings for this root.'
SH
}
data_paths() {
    local d=$OUT/data-paths-deb p
    rm -rf "$d"
    mkdir -p "$d/DEBIAN"
    printf '%s\n' 'Package: pie-image-test' 'Version: 1' 'Architecture: darwin-arm64' \
        'Maintainer: Test <test@example.invalid>' 'Description: files on the data paths' > "$d/DEBIAN/control"
    for p in private/var/db usr/local/share usr/share; do
        mkdir -p "$d/$p/pie-image-test"
        echo test > "$d/$p/pie-image-test/data"
    done
    (cd "$d" && find private usr -type f -exec md5sum {} + > DEBIAN/md5sums)
    dpkg-deb -Zxz --root-owner-group -b "$d" "$OUT/pie-image-test.deb" || return 1
    remote 'cat > /tmp/pie-image-test.deb' < "$OUT/pie-image-test.deb" || return 1
    privileged_input "sh -s -- $ROOT_ZFS" <<'SH'
set -u
trap 'rm -f /tmp/pie-image-test.deb' EXIT
data="/private/var/db/pie-image-test/data /usr/local/share/pie-image-test/data"
zfs=$1
apt-get install -y /tmp/pie-image-test.deb || exit 1
test -f /usr/share/pie-image-test/data || exit 1
for f in $data; do
    if [ $zfs = 1 ] && [ -e "$f" ]; then echo "$f is installed on a ZFS root."; exit 1; fi
    if [ $zfs = 0 ] && [ ! -f "$f" ]; then echo "$f is missing."; exit 1; fi
    if [ $zfs = 1 ]; then echo "$f: left out"; else echo "$f: installed"; fi
done
apt-get purge -y pie-image-test || exit 1
for f in $data /usr/share/pie-image-test/data; do
    if [ -e "$f" ]; then echo "$f is left after the purge."; exit 1; fi
done
if dpkg-query -W pie-image-test 2>/dev/null; then echo 'pie-image-test is still known to dpkg.'; exit 1; fi
out=$(dpkg --audit) && [ -z "$out" ] || { printf '%s\n' "$out"; exit 1; }
echo 'apt and dpkg installed and purged pie-image-test.'
SH
}
partition_tables() {
    python3 - "$OUT/first16m-before.bin" "$OUT/sd.img" "$ROOT_ZFS" <<'PY'
import os
import struct
import sys
import zlib
before = open(sys.argv[1], 'rb').read(34 * 512)
n = os.path.getsize(sys.argv[2]) // 512
with open(sys.argv[2], 'rb') as f:
    head = f.read(34 * 512)
    f.seek((n - 33) * 512)
    tail = f.read(33 * 512)
assert head[:462] == before[:462] and head[478:512] == before[478:512], 'the MBR changed'
p2, b2 = head[462:478], before[462:478]
if sys.argv[3] == '1':
    start, size = struct.unpack_from('<II', p2, 8)
    assert p2[:5] == b2[:5] and p2[8:12] == b2[8:12], 'partition 2 changed'
    assert size >= struct.unpack_from('<I', b2, 12)[0] and start + size <= n - 2048, 'partition 2 has a wrong size'
    print('Partition 2 ends %d sectors before the end of the card.' % (n - start - size))
else:
    assert p2 == b2, 'partition 2 changed'
if before[512:520] != b'EFI PART':
    assert head[512:].count(0) == 33 * 512, 'sectors 1 to 33 are not zero'
    print('The image has no GPT, and sectors 1 to 33 are zero.')
    sys.exit()
def header(h, my, alt, at, ents):
    hh = bytearray(h[:92])
    hh[16:20] = bytes(4)
    assert struct.unpack_from('<8sIII', h, 0) == (b'EFI PART', 0x10000, 92, zlib.crc32(hh)), 'header CRC'
    assert h[20:24].count(0) == 4 and h[92:512].count(0) == 420, 'reserved bytes'
    assert struct.unpack_from('<QQQQ', h, 24) == (my, alt, 34, n - 34), 'header LBAs'
    assert struct.unpack_from('<QIII', h, 72) == (at, 128, 128, zlib.crc32(ents)), 'entries'
    assert h[56:72] == before[512 + 56:512 + 72], 'disk GUID'
ents = head[1024:]
assert ents == before[1024:], 'the GPT entries changed'
header(head[512:1024], 1, n - 1, 2, ents)
assert tail[:-512] == ents, 'the backup entries differ'
header(tail[-512:], n - 1, 1, n - 33, ents)
print('Both GPT headers are valid for %d sectors, with the image\'s entries.' % n)
PY
}
loader_area() {
    cmp <(tail -c +$((34 * 512 + 1)) "$OUT/first16m-before.bin") \
        <(head -c $((32768 * 512)) "$OUT/sd.img" | tail -c +$((34 * 512 + 1))) &&
        echo 'Sectors 34 to 32767 are unchanged.'
}
wait_up "$OUT/console.log" ''
if grep -aE '(^|[[:space:]])login:' "$OUT/console.log" > "$OUT/login.txt"; then record PASS login; else record FAIL login; fi
if ((UP)); then
    collect
    if grep -q '^u-boot-rk3566 ' "$MANIFEST"; then check loader-skips loader_skips; fi
    if grep -q '^piewifi ' "$MANIFEST"; then check wifi-watch wifi_idle; fi
    if grep -q '^pie-zfsroot ' "$MANIFEST"; then check zfs-settings zfs_settings; fi
    check data-paths data_paths
    accounts
    reboot_guest || true
    if grep -aE '(^|[[:space:]])login:' "$OUT/console-reboot.log" > "$OUT/login-after-reboot.txt" 2>&1; then
        record PASS login-after-reboot
    else
        record FAIL login-after-reboot
    fi
else
    blocked 'SSH unavailable. See console.log and ssh-probe.txt.'
fi
stop
trap - EXIT
exec 3>&-
check loader-area loader_area
check partition-tables partition_tables
if grep -aF 'panic(cpu' "$OUT"/console*.log > "$OUT/console-panics.txt"; then record FAIL console-panics; else record PASS console-panics; fi
check console-kernel python3 "$HERE/kernel.py" "$OUT/fat/xnu.bundle" "$OUT/console-members" "$OUT/console.log"
printf 'exit=%s\n' "$FAILED" | tee "$OUT/exit.txt"
exit "$FAILED"
