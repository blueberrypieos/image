#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: source common.sh from a test entry point.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export FAILED=0
record() {
    printf '%s %s\n' "$1" "$2" | tee -a "$OUT/results.txt"
    if [[ $1 != PASS ]]; then FAILED=1; fi
}
check() {
    local name=$1
    shift
    if "$@" > "$OUT/$name.txt" 2>&1; then record PASS "$name"; else record FAIL "$name"; fi
}
remote() { "${SSH[@]}" "$@"; }
privileged() { printf '%s\n' "$PIE_PASSWORD" | as_root "$@"; }
privileged_input() { { printf '%s\n' "$PIE_PASSWORD"; cat; } | as_root "$@"; }
as_root() {
    local command=$*
    command=${command//\'/\'\\\'\'}
    "${ADMIN_SSH[@]}" "sudo -k -S -p '' sh -c '$command'"
}
prepare() {
    mkdir -p "$OUT"
    OUT=$(cd -- "$OUT" && pwd)
    [[ ! -e $OUT/results.txt ]] || { echo 'Use a new output directory.' >&2; exit 2; }
    cp -- "$MANIFEST" "$OUT/manifest"
    awk '{print $1 " " $2}' "$MANIFEST" | LC_ALL=C sort > "$OUT/expected-packages.txt"
    VERSION=$(awk '$1 == "blueberry-pie-os-kernel" {print $2}' "$MANIFEST")
    [[ -n $VERSION ]] || { echo 'No kernel in manifest.' >&2; exit 2; }
    ARCHIVE_URL=${ARCHIVE_URL:-https://blueberrypieos.com/apt/}
    GUEST_ARCHIVE_URL=${GUEST_ARCHIVE_URL:-$ARCHIVE_URL}
    ARCHIVE_KEYRING=${ARCHIVE_KEYRING:-$HERE/../keys/blueberry-pie-os-archive-keyring.gpg}
    ARCHIVE_KEYRING=$(realpath -- "$ARCHIVE_KEYRING")
    check archive python3 "$HERE/archive.py" "$OUT/archive" "$ARCHIVE_KEYRING" "$VERSION" "$ARCHIVE_URL"
}
blocked() {
    local name
    for name in ssh uname uuid kernel-file kextstat logs dpkg-audit packages apt-update apt-key runtime-kernel; do
        printf 'BLOCKED: %s\n' "$1" > "$OUT/$name.txt"
        record BLOCKED "$name"
    done
}
identity_check() {
    python3 - "$OUT" <<'PY'
import hashlib
import json
import re
from pathlib import Path
import sys
p = Path(sys.argv[1])
items = json.loads((p / 'members/identity.json').read_text())
uuid = (p / 'uuid.txt').read_text().strip().split()[-1]
selected = [v for v in items.values() if v.get('uuid') == uuid.upper()]
assert len(selected) == 1, 'running UUID is absent from bundle'
console = (p / 'console.log').read_text(errors='replace')
loaded = re.search(r'pieboot: kernel (bcm\d+)', console)
assert loaded and items['kernel.' + loaded[1]]['uuid'] == uuid.upper(), 'selected kernel UUID differs'
assert (p / 'uname.txt').read_text().strip() == selected[0]['uname'], 'version differs'
expected = hashlib.sha256((p / 'fat/xnu.bundle').read_bytes()).hexdigest()
assert (p / 'kernel-file.txt').read_text().split()[0] == expected, 'installed bundle differs'
print('Running UUID and version match bundle member:', uuid)
print('Installed bundle SHA256:', expected)
PY
}
collect() {
    check ssh remote 'sh -s' <<'SH'
id
test "$(id -un)" = pie
SH
    check uname remote 'uname -v'
    check uuid remote 'sysctl kern.uuid'
    check kernel-file remote 'sha256sum /usr/lib/blueberry-pie-os/boot/xnu.bundle'
    check kextstat remote 'kextstat'
    if ! grep -qi 'piegpio' "$OUT/kextstat.txt"; then record FAIL piegpio; else record PASS piegpio; fi
    check logs privileged 'dmesg && cat /var/log/system.log'
    if grep -aF 'panic(cpu' "$OUT/logs.txt" > "$OUT/log-panics.txt"; then record FAIL log-panics; else record PASS log-panics; fi
    check dpkg-audit remote 'dpkg --audit'
    if [[ -s $OUT/dpkg-audit.txt ]]; then record FAIL audit-empty; else record PASS audit-empty; fi
    check packages remote 'sh -s' <<'SH'
dpkg-query -W -f='${Package} ${Version}\n'
SH
    LC_ALL=C sort "$OUT/packages.txt" > "$OUT/actual-packages.txt"
    check manifest-match diff -u "$OUT/expected-packages.txt" "$OUT/actual-packages.txt"
    local apt_work apt_command components
    apt_work=$(remote 'mktemp -d /tmp/pie-apt-test.XXXXXX')
    printf -v apt_command 'cat > %q/key.gpg' "$apt_work"
    remote "$apt_command" < "$ARCHIVE_KEYRING"
    components=$(sed -n 's/^Components: //p' "$OUT/archive/Release")
    printf -v apt_command 'sh -s -- %q %q %q' "$apt_work" "$GUEST_ARCHIVE_URL" "$components"
    check apt-update remote "$apt_command" <<'SH'
set -eu
w=$1
url=$2
components=$3
chmod 755 "$w"
chmod 644 "$w/key.gpg"
printf 'deb [signed-by=%s/key.gpg] %s blueberry-pie-os %s\n' "$w" "$url" "$components" > "$w/sources.list"
mkdir -p "$w/lists/partial" "$w/cache/archives/partial" "$w/log" "$w/sourceparts"
cat "$w/sources.list"
apt -o Dir::Etc::sourcelist="$w/sources.list" -o Dir::Etc::sourceparts="$w/sourceparts" -o Dir::State::lists="$w/lists" -o Dir::Cache="$w/cache" -o Dir::Log="$w/log" -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false -o APT::Get::AllowUnauthenticated=false -o Debug::pkgAcquire::Auth=true -o Debug::Acquire::gpgv=true -o APT::Update::Error-Mode=any update
SH
    printf -v apt_command 'cat %q/key.gpg' "$apt_work"
    check apt-key remote "$apt_command"
    printf -v apt_command 'rm -rf -- %q' "$apt_work"
    remote "$apt_command"
    if python3 - "$OUT" > "$OUT/apt-key-decode.txt" 2>&1 <<'PYKEY'
import base64
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = (p / 'apt-key.txt').read_bytes()
if data.startswith(b'-----BEGIN'):
    s = data.decode().split('\n\n', 1)[1].split('-----END')[0]
    s = ''.join(x for x in s.splitlines() if not x.startswith('='))
    data = base64.b64decode(s, validate=True)
(p / 'guest-key.gpg').write_bytes(data)
PYKEY
    then
        check apt-key-signature gpgv --status-fd=1 --keyring "$OUT/guest-key.gpg" "$OUT/archive/InRelease"
    else
        record FAIL apt-key-decode
    fi
    if grep -Fq "$GUEST_ARCHIVE_URL" "$OUT/apt-update.txt" &&
       grep -Eqi 'Signature verification succeeded|GOODSIG|VALIDSIG|Signature verification successful' "$OUT/apt-update.txt"; then
        record PASS apt-signature
    else
        record FAIL apt-signature
    fi
    check runtime-kernel identity_check
}
compare_bundle() {
    check bundle-match cmp "$OUT/fat/xnu.bundle" "$OUT/archive/extracted/usr/lib/blueberry-pie-os/boot/xnu.bundle"
    check bundle-identity python3 "$HERE/kernel.py" "$OUT/fat/xnu.bundle" "$OUT/members"
}
