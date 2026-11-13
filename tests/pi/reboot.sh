#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: reboot.sh root@HOST KNOWN_HOSTS OUTPUT trial|pieb|good
# Reboots the Pi and waits for it. Passes if it comes back in the expected
# slot: trial has pie.slot=trial in kern.bootargs, good has no pie.slot=.
# pieb is a trial that must also run the system in /pie-b: launchdsuffix=pieb
# is in kern.bootargs, /etc/pie-b-id exists and /pie-b does not.
# Exits 3 if the Pi is not back in PI_REBOOT_WAIT seconds, 360 by default.
# Make that longer than B's pie_watchdog_boot plus a boot of A.
[[ $# == 4 && ($4 == trial || $4 == pieb || $4 == good) ]] || { sed -n '4p' "$0" >&2; exit 2; }
HOST=$1 KNOWN=$2 OUT=$3 WANT=$4 SYSTEM=
[[ $WANT == pieb ]] && WANT=trial SYSTEM=pieb
source "$(dirname -- "$0")/lib.sh"
WAIT=${PI_REBOOT_WAIT:-360}
[[ $WAIT =~ ^[0-9]+$ ]] && ((WAIT >= 120)) || { echo 'PI_REBOOT_WAIT must be 120 or more.' >&2; exit 2; }
probe() { timeout 20 "${ROOT_SSH[@]}" "$@" < /dev/null 2>/dev/null; }
left() { echo $((END - SECONDS)); }
bounded() {
    local t
    t=$(left)
    ((t > 20)) && t=20
    ((t > 0)) || return 1
    timeout "$t" "${ROOT_SSH[@]}" "$@" < /dev/null 2>/dev/null
}
before=$(probe 'sysctl -n kern.boottime') || { say "FAIL: no ssh before the reboot"; exit 1; }
say "reboot $HOST, expecting slot $WANT"
start=$SECONDS END=$((SECONDS + WAIT))
probe 'sync; (sleep 1; reboot) > /dev/null 2>&1 &' || true
down=0
while ((SECONDS - start < 120)); do
    if ! probe true; then down=1; break; fi
    sleep 2
done
((down)) || { say "FAIL: the Pi did not go down in 120 s"; exit 1; }
up=0
while (($(left) > 0)); do
    if bounded true; then up=1; break; fi
    t=$(left); ((t > 5)) && t=5; ((t > 0)) && sleep "$t"
done
((up)) || { say "FAIL: no ssh $WAIT s after the reboot. Wait longer before you decide the card has to come out."; exit 3; }
after=$(bounded 'sysctl -n kern.boottime') && args=$(bounded 'sysctl -n kern.bootargs') ||
    { say "FAIL: ssh came and went, or the $WAIT s ran out"; exit 3; }
printf '%s\n' "$args" > "$OUT/bootargs.txt"
slot=$(tr ' ' '\n' <<< "$args" | sed -n 's/^pie\.slot=//p')
slot=${slot:-good}
say "back after $((SECONDS - start)) s, slot $slot, boot-args: $args"
[[ $before != "$after" ]] || { say "FAIL: kern.boottime did not change"; exit 1; }
[[ $slot == "$WANT" ]] || { say "FAIL: slot $slot, expected $WANT"; exit 1; }
if [[ $SYSTEM == pieb ]]; then
    [[ " $args " == *" launchdsuffix=pieb "* ]] || { say "FAIL: no launchdsuffix=pieb in kern.bootargs"; exit 1; }
    id=$(bounded 'cat /etc/pie-b-id && [ ! -e /pie-b ]') ||
        { say "FAIL: the system that came up is not the one in /pie-b"; exit 1; }
    say "running the system in /pie-b, id $id"
fi
say "PASS: slot $slot${SYSTEM:+, system $SYSTEM}"
