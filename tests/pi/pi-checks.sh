#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: pi-checks.sh root@HOST KNOWN_HOSTS OUTPUT AREA
# Runs one area of checks on the system in /pie-b while it runs, and
# writes PASS or FAIL lines to OUTPUT/results.txt. OUTPUT must be new.
# AREA is one of:
#   kernel     the running kernel is a member of PI_BUNDLE, the installed
#              blueberry-pie-os-kernel is PI_KERNEL, kexts, watchdog, CPUs
#   storage    fsck_hfs -l -n of the root volume, the boot partition
#              read-only and as PI_FAT_SUMS has it, and a 64 MB file
#              written and read back through the cache. fsck_hfs -l
#              holds the volume still while it runs.
#   network    an IPv4 address on en0, dhcpc, mDNSResponder, the gateway, DNS
#   clock      /var/run/clock-synced, and the clock within 5 s of this host
#   logging    syslogd, and a logger line from pie in /var/log/system.log
#   login      pie by password, sudo, su
#   audit      auditd, and pie's login in a trail that was opened just
#              before it and closed just after it
#   passwords  passwd as pie, ssh, sudo and chkpasswd with the old and the
#              new password, then the password changed back. Root sets
#              the old password again if anything fails.
#   users      makes ann, uid 502, with dscl, and checks ssh and sudo. It
#              refuses if ann or uid 502 exists. ann stays for accounts.
#   accounts   OpenDirectory, the records, ids and owners, ann included
#   sysmon     ps as pie
#   cleanup    takes ann away, if the users area made it
# Root logs in by key. pie logs in with PIE_PASSWORD, blueberry by default.
# passwords uses PIE_NEW_PASSWORD, and users ANN_PASSWORD. accounts needs
# LIST_ACCOUNTS, a darwin-arm64 build of tests/list-accounts.c. The
# account and password checks are the functions of tests/qemu-boot.sh.
# Before any area it checks that the hardware watchdog is armed and that
# deadman is checking in for B, with a fresh heartbeat. PI_NO_DEADMAN=1
# skips this check, and PI_QEMU=1 skips the armed watchdog, which QEMU
# lacks. Exits 1 if a check fails.
[[ $# == 4 ]] || { sed -n '4p' "$0" >&2; exit 2; }
HOST=$1 KNOWN=$2 OUT=$3 AREA=$4
case $AREA in
    kernel|storage|network|clock|logging|login|audit|accounts|passwords|users|sysmon|cleanup) ;;
    *) sed -n '7,20p' "$0" >&2; exit 2 ;;
esac
[[ ! -e $OUT/results.txt ]] || { echo 'Use a new output directory.' >&2; exit 2; }
source "$(dirname -- "$0")/lib.sh"
source "$(dirname -- "$0")/../common.sh"
for f in account_state ann_checks accounts_unique ssh_refused sudo_refused chkpasswd_new sudo_id \
    ann_ssh ann_sudo as_old as_ann prompts; do
    source <(awk -v f="$f" '
        !p && index($0, f "() {") == 1 { print; if ($0 != f "() {") exit; p = 1; next }
        !p { next }
        hd != "" { print; if ($0 == hd) hd = ""; next }
        match($0, /<<-?'"'"'?[A-Z]+'"'"'?/) { hd = substr($0, RSTART, RLENGTH); gsub(/[<'"'"'-]/, "", hd) }
        { print; if ($0 == "}") exit }' "$HERE/qemu-boot.sh")
    declare -F "$f" > /dev/null || { echo "qemu-boot.sh has no function $f" >&2; exit 2; }
done
IP=${HOST#root@}
PORT=${PI_SSH_PORT:-22}
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
SSH_OPTS=(ssh -F /dev/null -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN"
    -o ConnectTimeout=10 -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o PreferredAuthentications=password
    -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -p "$PORT")
SSH=("${SSH_OPTS[@]}" "pie@$IP")
TTY_SSH=("${SSH_OPTS[@]}" -tt "pie@$IP")
ANN_SSH=("${SSH_OPTS[@]}" "ann@$IP")
ADMIN_SSH=("${SSH[@]}")
as_root_key() { rrun "$1" < /dev/null; }
rcheck() { check "$1" as_root_key "$2"; }
greps() { grep -E "$2" "$OUT/$1.txt" > /dev/null; }
verdict() { if "${@:2}"; then record PASS "$1"; else record FAIL "$1"; fi; }

rcheck pieb 'set -eu
args=$(sysctl -n kern.bootargs)
echo "$args"
case " $args " in *" launchdsuffix=pieb "*) ;; *) echo "no launchdsuffix=pieb"; exit 1 ;; esac
cat /etc/pie-b-id
[ ! -e /pie-b ]'
((FAILED == 0)) || { echo 'Not the system in /pie-b: no checks run.' >&2; exit 1; }
if [[ ${PI_NO_DEADMAN:-} != 1 ]]; then
    rcheck deadman "set -eu
e=\$(sysctl -n hw.watchdog.enabled)
echo \"enabled \$e\"
[ \"\$e\" = 1 ] || [ '${PI_QEMU:-}' = 1 ]
"'t=$(sysctl -n hw.watchdog.user_timeout)
p=$(sysctl -n hw.watchdog.user_pid)
echo "user_timeout $t, user_pid $p"
[ "$t" -gt 0 ]
[ "$p" -gt 0 ]
c=$(ps -p "$p" -o comm=)
echo "$c"
case "$c" in *deadman) ;; *) exit 1 ;; esac
hbf=/var/tmp/pie-heartbeat
if [ -f /var/run/pie-b-heartbeat ] && { [ ! -f "$hbf" ] || [ /var/run/pie-b-heartbeat -nt "$hbf" ]; }; then hbf=/var/run/pie-b-heartbeat; fi
echo "heartbeat file $hbf"
age=$(( $(date +%s) - $(stat -f %m "$hbf") ))
echo "heartbeat $age s old"
[ "$age" -lt 90 ]
r1=$(sysctl -n hw.watchdog.user_remaining)
sleep 6
r2=$(sysctl -n hw.watchdog.user_remaining)
echo "user_remaining $r1 ms, then $r2 ms"
[ "$r2" -gt $((r1 - 3000)) ]'
    ((FAILED == 0)) || { echo 'deadman is not checking in for B: no checks run.' >&2; exit 1; }
fi

case $AREA in
kernel)
    [[ -n ${PI_BUNDLE:-} && -n ${PI_KERNEL:-} ]] || { echo 'Set PI_BUNDLE and PI_KERNEL.' >&2; exit 2; }
    rcheck uname 'uname -v'
    rcheck uuid 'sysctl kern.uuid'
    rcheck kernel-file 'sum /usr/lib/blueberry-pie-os/boot/xnu.bundle'
    check bundle-members python3 "$HERE/kernel.py" "$PI_BUNDLE" "$OUT/members"
    check runtime-kernel python3 - "$OUT" "$PI_BUNDLE" <<'PY'
import hashlib, json, sys
from pathlib import Path
p = Path(sys.argv[1])
items = json.loads((p / 'members/identity.json').read_text())
uuid = (p / 'uuid.txt').read_text().split()[-1].upper()
member = [k for k, v in items.items() if v.get('uuid') == uuid]
assert len(member) == 1, 'running UUID %s is not in the bundle' % uuid
assert (p / 'uname.txt').read_text().strip() == items[member[0]]['uname'], 'version differs'
want = hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
assert (p / 'kernel-file.txt').read_text().split()[0] == want, 'the installed bundle differs'
print('running', member[0], uuid)
PY
    rcheck kernel-package "dpkg-query -W -f='\${Version}\n' blueberry-pie-os-kernel | tee /dev/stderr | grep -qx '$PI_KERNEL'"
    rcheck kextstat 'kextstat'
    verdict piegpio greps kextstat piegpio
    verdict watchdog-kext greps kextstat '[Ww]atchdog'
    rcheck watchdog 'sysctl hw.watchdog'
    verdict watchdog-enabled greps watchdog '^hw\.watchdog\.enabled: 1$'
    rcheck cpus 'sysctl -n hw.ncpu | grep -qx 4'
    rcheck no-panics 'ls -l /var/log/panic-* 2>/dev/null && exit 1; echo none'
    rcheck dpkg-audit 'out=$(dpkg --audit) || exit 1; printf "%s\n" "$out"; [ -z "$out" ]'
    ;;
storage)
    [[ -s ${PI_FAT_SUMS:-} ]] || { echo 'Set PI_FAT_SUMS to the fat-sums-expected.txt of trial.sh setup.' >&2; exit 2; }
    rcheck fsck 'set -eu
dev=$(df / | awk "NR == 2 {print \$1}")
echo "$dev"
fsck_hfs -l -n "/dev/r${dev#/dev/}"'
    rcheck boot-partition 'set -eu
fat_mount rdonly
trap fat_umount EXIT
fat_sums'
    check boot-partition-sums diff -u "$PI_FAT_SUMS" "$OUT/boot-partition.txt"
    rcheck write-read 'set -eu
f=$(mktemp /var/tmp/pi-checks.XXXXXX)
trap "rm -f $f" EXIT
dd if=/dev/random of=$f bs=1048576 count=64 2> /dev/null
a=$(sum < $f)
sync
b=$(sum < $f)
echo "$a"
[ "$a" = "$b" ]
[ "$(wc -c < $f | tr -d " ")" = 67108864 ]'
    ;;
network)
    rcheck en0 'ifconfig en0'
    verdict ipv4 greps en0 '^[[:space:]]inet [0-9.]+ '
    rcheck dhcpc 'pgrep -l dhcpc'
    rcheck mdns 'pgrep -lx mDNSResponder'
    rcheck gateway 'set -eu
gw=$(route -n get default | awk "/gateway:/ {print \$2}")
echo "gateway $gw"
[ -n "$gw" ]
ping -c 3 -t 15 "$gw"'
    rcheck dns 'ping -c 1 -t 5 blueberrypieos.com 2>&1 | tee /dev/stderr | head -1 | grep -q "^PING blueberrypieos.com ([0-9.]*)"'
    ;;
clock)
    rcheck clock-synced 'ls -l /var/run/clock-synced'
    rcheck clock-remote 'date -u +%s'
    here=$(date -u +%s) there=$(tr -dc 0-9 < "$OUT/clock-remote.txt")
    printf 'here %s, there %s\n' "$here" "$there" > "$OUT/clock-offset.txt"
    verdict clock-offset test "$(( here > there ? here - there : there - here ))" -le 5
    ;;
logging)
    n=pi-checks-$(date -u +%s)-$$
    rcheck syslogd 'pgrep -lx syslogd'
    check logger remote "logger -t pi-checks $n"
    sleep 3
    rcheck system-log "grep -F 'pi-checks' /var/log/system.log | grep -F '$n'"
    ;;
login)
    check ssh remote 'id; test "$(id -un)" = pie'
    check sudo sudo_id
    check su prompts -- "${TTY_SSH[@]}" "su pie -c 'echo SU-\$(id -un)-\$(id -u)'" <<'STEPS'
expect (?i)password:
secret PIE_PASSWORD
expect SU-pie-501
STEPS
    ;;
audit)
    rcheck auditd 'pgrep -lx auditd'
    rcheck trail-open 'set -eu
c0=$(readlink /var/audit/current)
audit -n
sleep 3
ls -l /var/audit
c1=$(readlink /var/audit/current)
[ "$c1" != "$c0" ]
[ -e "$c1" ]
open=$(ls /var/audit | grep -c "not_terminated\$" || true)
[ "$open" = 1 ]
echo "$c1"'
    check login remote 'id -un'
    sleep 2
    trail=$(tail -1 "$OUT/trail-open.txt")
    rcheck trail-closed "set -eu
trap 'rm -f /var/tmp/pi-checks-trail.txt' EXIT
audit -n
sleep 3
ls -l /var/audit
c2=\$(readlink /var/audit/current)
[ \"\$c2\" != '$trail' ]
[ -e \"\$c2\" ]
[ ! -e '$trail' ]
b=\$(basename '$trail' .not_terminated)
closed=\$(ls /var/audit | grep \"^\$b\\.[0-9]*\$\")
echo \"closed: \$closed\"
praudit -l /var/audit/\$closed > /var/tmp/pi-checks-trail.txt || true
[ -s /var/tmp/pi-checks-trail.txt ]
grep -i ssh /var/tmp/pi-checks-trail.txt | grep ',pie,'"
    ;;
accounts)
    account_state ''
    ;;
passwords)
    old_back() {
        if PIE_PASSWORD=$PIE_OLD_PASSWORD remote true < /dev/null > /dev/null 2>&1; then return 0; fi
        printf '%s\n' "$PIE_OLD_PASSWORD" | rrun 'read -r p; dscl . -passwd /Users/pie "$p"' > "$OUT/passwd-reset.txt" 2>&1 || true
        record FAIL passwd-reset-by-root
        if PIE_PASSWORD=$PIE_OLD_PASSWORD remote true < /dev/null >> "$OUT/passwd-reset.txt" 2>&1; then
            record PASS passwd-restored
        else
            record FAIL passwd-restored
        fi
    }
    trap old_back EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
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
        check ssh-old-refused ssh_refused
        check ssh-new remote 'test "$(id -un)" = pie'
        check sudo-old-refused sudo_refused
        check sudo-new sudo_id
        check chkpasswd-old-refused prompts -- "${TTY_SSH[@]}" /usr/libexec/chkpasswd <<'STEPS'
expect (?i)password:
secret PIE_OLD_PASSWORD
expect Sorry
STEPS
        check chkpasswd-new chkpasswd_new
        check passwd-back prompts -- "${TTY_SSH[@]}" passwd <<'STEPS'
expect (?i)password:
secret PIE_NEW_PASSWORD
expect (?i)password:
secret PIE_OLD_PASSWORD
expect (?i)password:
secret PIE_OLD_PASSWORD
status 0
STEPS
        export PIE_PASSWORD=$PIE_OLD_PASSWORD
        check ssh-old-again remote 'test "$(id -un)" = pie'
    else
        record FAIL passwd-change
        export PIE_PASSWORD=$PIE_OLD_PASSWORD
    fi
    old_back
    trap - EXIT HUP INT TERM
    ;;
users)
    rcheck ann-absent 'if dscl . -read /Users/ann > /dev/null 2>&1 || id 502 > /dev/null 2>&1 || [ -e /Users/ann ]; then
    echo "ann, uid 502 or /Users/ann exists"; exit 1; fi'
    ((FAILED == 0)) || { echo 'ann is there already: nothing changed.' >&2; exit 1; }
    check ann-create privileged_input 'sh -s' <<'SH'
set -eu
dscl . -create /Users/ann
g=$(dscl . -read /Users/ann GeneratedUID | awk '{print $2}')
[ -n "$g" ]
(umask 077; echo "$g" > /var/db/pi-checks-ann)
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
    ;;
cleanup)
    rcheck ann-removed 'set -eu
[ -s /var/db/pi-checks-ann ] || { echo "no /var/db/pi-checks-ann: ann was not made by the users area"; exit 1; }
g=$(dscl . -read /Users/ann GeneratedUID | awk "{print \$2}")
[ "$g" = "$(cat /var/db/pi-checks-ann)" ] || { echo "ann is not the account the users area made"; exit 1; }
dscl . -delete /Groups/admin GroupMembership ann 2> /dev/null || true
dscl . -delete /Users/ann 2> /dev/null || true
rm -rf /Users/ann
if dscl . -read /Users/ann > /dev/null 2>&1; then exit 1; fi
[ ! -e /Users/ann ]
if dscl . -read /Groups/admin GroupMembership 2> /dev/null | grep -qw ann; then exit 1; fi
rm -f /var/db/pi-checks-ann
echo "ann removed"'
    ;;
sysmon)
    check ps remote 'ps axo pid,user,comm | tee /dev/stderr | grep -q "launchd$"'
    ;;
esac
printf 'exit=%s\n' "$FAILED" | tee "$OUT/exit.txt"
exit "$FAILED"
