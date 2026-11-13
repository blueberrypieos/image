#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: deadman.sh start root@HOST KNOWN_HOSTS OUTPUT DEADMAN
#        deadman.sh beat|stop root@HOST KNOWN_HOSTS OUTPUT
# start copies DEADMAN, a darwin-arm64 build of deadman.c, to
# /var/tmp/deadman on the Pi, and runs it there as deadman 60 120 with
# the heartbeat file /var/tmp/pie-heartbeat. It passes once deadman
# checks in with the kernel. From then on, if the heartbeat file does not
# change for 120 s, the check-ins stop and the kernel panics 60 s later.
# beat touches the heartbeat file every 30 s until it is stopped. Run it in
# the background while other steps run, and stop it with kill. stop sends
# deadman SIGUSR1, which ends the check-ins. Then nothing checks in for
# the system: neither deadman nor the boot deadline protects it any more.
# Any other way deadman ends leaves its last check-in in force.
ACTION=${1:-}
case $ACTION in
    start) [[ $# == 5 ]] || { sed -n '4,5p' "$0" >&2; exit 2; } ;;
    beat|stop) [[ $# == 4 ]] || { sed -n '4,5p' "$0" >&2; exit 2; } ;;
    *) sed -n '4,5p' "$0" >&2; exit 2 ;;
esac
HOST=$2 KNOWN=$3 OUT=$4
source "$(dirname -- "$0")/lib.sh"
HB=/var/tmp/pie-heartbeat
case $ACTION in
start)
    DM=$(realpath -- "$5")
    rsh "! pgrep -x deadman > /dev/null" < /dev/null || { say "FAIL: deadman runs already"; exit 1; }
    push "$DM" /var/tmp/deadman || exit 1
    rsh "set -e
chmod 755 /var/tmp/deadman
touch $HB
nohup /var/tmp/deadman 60 120 $HB > /var/tmp/deadman.log 2>&1 < /dev/null &
sleep 8
cat /var/tmp/deadman.log
t=\$(sysctl -n hw.watchdog.user_timeout)
p=\$(sysctl -n hw.watchdog.user_pid)
echo \"user_timeout \$t, user_pid \$p\"
[ \"\$t\" -gt 0 ]
ps -p \"\$p\" -o comm= | grep -q 'deadman\$'" < /dev/null > "$OUT/deadman-start.txt" 2>&1 ||
        { say "FAIL: deadman does not check in; see $OUT/deadman-start.txt"; exit 1; }
    sleep 5
    rsh "set -e
touch $HB
pgrep -x deadman
r1=\$(sysctl -n hw.watchdog.user_remaining)
sleep 6
r2=\$(sysctl -n hw.watchdog.user_remaining)
echo \"user_remaining \$r1 ms, then \$r2 ms\"
[ \"\$r2\" -gt \$((r1 - 3000)) ]" < /dev/null >> "$OUT/deadman-start.txt" 2>&1 ||
        { say "FAIL: deadman stopped checking in after its ssh session ended; see $OUT/deadman-start.txt"; exit 1; }
    say "PASS: deadman checks in; run deadman.sh beat now"
    ;;
beat)
    say "heartbeat every 30 s"
    while :; do
        timeout 20 "${ROOT_SSH[@]}" "touch $HB" < /dev/null || say "heartbeat failed"
        sleep 30
    done
    ;;
stop)
    rsh "set -e
pkill -USR1 -x deadman
sleep 7
t=\$(sysctl -n hw.watchdog.user_timeout)
echo \"user_timeout \$t\"
[ \"\$t\" = 0 ]
cat /var/tmp/deadman.log" < /dev/null > "$OUT/deadman-stop.txt" 2>&1 ||
        { say "FAIL: see $OUT/deadman-stop.txt"; exit 1; }
    say "PASS: the check-ins ended; nothing protects the system now"
    ;;
esac
