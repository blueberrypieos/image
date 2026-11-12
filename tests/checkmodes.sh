#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: checkmodes.sh
set -euo pipefail
[[ $# == 0 ]] || { sed -n '4p' "$0" >&2; exit 2; }
TOOLS=$(cd -- "$(dirname -- "$0")/../tools" && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAKEROOT="$W/fakeroot"
: > "$FAKEROOT"
fr() { fakeroot -i "$FAKEROOT" -s "$FAKEROOT" -- "$@"; }
FAILED=0
expect() {
    local want=$1 name=$2 pattern=$3 got=0
    shift 3
    "$@" > "$W/$name.txt" 2>&1 || got=1
    if [[ $got == "$want" ]] && grep -q -- "$pattern" "$W/$name.txt"; then
        echo "PASS $name"
    else
        echo "FAIL $name"
        sed 's/^/  /' "$W/$name.txt"
        FAILED=1
    fi
}

P="$W/pkg"
mkdir -p "$P/DEBIAN" "$P/private/etc" "$P/private/var/at/jobs" "$P/private/var/at/spool" "$P/private/var/msgs"
cat > "$P/DEBIAN/control" <<'EOF'
Package: at-test
Version: 1
Architecture: darwin-arm64
Maintainer: Maxwell <Maxwell>
Description: checkmodes test
EOF
cat > "$P/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
	for d in /private/var/at /private/var/at/jobs /private/var/at/spool; do
		dpkg-statoverride --list "$d" > /dev/null ||
			dpkg-statoverride --update --add '#1' '#0' 0755 "$d"
	done
	dpkg-statoverride --list /private/var/msgs > /dev/null ||
		dpkg-statoverride --update --add '#1' '#1' 0755 /private/var/msgs
fi
EOF
printf 'root:*:0:0:System Administrator:/var/root:/bin/sh\ndaemon:*:1:1:System Services:/var/root:/usr/bin/false\ndaemon:*:7:7:Duplicate:/var/empty:/usr/bin/false\n' > "$P/private/etc/passwd"
printf 'wheel:*:0:root\ndaemon:*:1:root\natrun:*:1:\n' > "$P/private/etc/group"
chmod 755 "$P/DEBIAN/postinst" "$P" "$P"/private "$P"/private/* "$P"/private/var/* "$P"/private/var/at/*
chmod 644 "$P/private/etc/passwd" "$P/private/etc/group"
ln -s ../../etc/passwd "$P/private/var/msgs/bounds"
DEB="$W/at-test_1_darwin-arm64.deb"
dpkg-deb --root-owner-group -Zxz -b "$P" "$DEB" > /dev/null

ROOT="$W/root"
SO="$ROOT/private/var/lib/dpkg/statoverride"
fr "$TOOLS/installroot.sh" "$ROOT" "$DEB"
cp "$SO" "$W/statoverride"
fr python3 "$TOOLS/mkhfs.py" "$ROOT" "$W/root.hfs" > /dev/null
check() { python3 "$TOOLS/checkmodes.py" "$@" "$W/root.hfs" "$DEB"; }
fsck_same() {
    cp --sparse=always "$1" "$W/fsck.hfs"
    fsck.hfsplus -f -y "$W/fsck.hfs" > "$W/fsck.log" 2>&1 || { cat "$W/fsck.log"; return 1; }
    cat "$W/fsck.log"
    cmp "$1" "$W/fsck.hfs"
}
volume_ok() {
    if command -v fsck.hfsplus > /dev/null; then
        expect 0 "fsck-$1" 'appears to be OK' fsck_same "$W/root.hfs"
    else
        echo "SKIP fsck-$1: no fsck.hfsplus"
    fi
}
volume_ok first

expect 0 recorded '^daemon wheel 755 /private/var/at/spool$' cat "$SO"
expect 0 recorded-group '^daemon daemon 755 /private/var/msgs$' cat "$SO"
expect 0 overrides '11 entries match' check -r "$ROOT"
expect 1 no-root '4 differences' check
printf '#1 #0 755 /private/var/at\ndaemon #0 755 /private/var/at/jobs\n#1 wheel 755 /private/var/at/spool\n#1 #1 755 /private/var/msgs\n' > "$SO"
expect 0 numeric '11 entries match' check -r "$ROOT"
sed 's|^.* /private/var/msgs$|daemon atrun 755 /private/var/msgs|' "$W/statoverride" > "$SO"
expect 0 group-name '11 entries match' check -r "$ROOT"
sed 's|^.* /private/var/msgs$|daemon wheel 755 /private/var/msgs|' "$W/statoverride" > "$SO"
expect 1 override-group '^/private/var/msgs: volume drwxr-xr-x 040755 1:1, statoverride drwxr-xr-x 040755 1:0$' check -r "$ROOT"
sed 's|^.* /private/var/at$|#2 #0 755 /private/var/at|' "$W/statoverride" > "$SO"
expect 1 override-owner '^/private/var/at: volume drwxr-xr-x 040755 1:0, statoverride drwxr-xr-x 040755 2:0$' check -r "$ROOT"
sed 's|^.* /private/var/at$|daemon wheel 750 /private/var/at|' "$W/statoverride" > "$SO"
expect 1 override-mode '^/private/var/at: volume drwxr-xr-x 040755 1:0, statoverride drwxr-x--- 040750 1:0$' check -r "$ROOT"
{ cat "$W/statoverride"; echo '#0 #0 755 /private/var/none'; } > "$SO"
expect 1 no-deb '^/private/var/none: statoverride has it, no deb does$' check -r "$ROOT"
{ cat "$W/statoverride"; echo '#2 #0 644 /private/none/../etc/passwd'; } > "$SO"
expect 1 not-normalised '^/private/none/../etc/passwd: statoverride has it, no deb does$' check -r "$ROOT"
{ cat "$W/statoverride"; echo '#0 #0 644 /private/etc/passwd/'; } > "$SO"
expect 1 trailing-slash '^/private/etc/passwd/: statoverride has it, no deb does$' check -r "$ROOT"
sed 's|^.* /private/var/at$|daemon wheel 755 /./private/var/at|' "$W/statoverride" > "$SO"
expect 0 dot-slash '11 entries match' check -r "$ROOT"
{ cat "$W/statoverride"; echo 'nobody wheel 755 /private/etc'; } > "$SO"
expect 1 unknown-user 'user nobody is not in' check -r "$ROOT"
{ cat "$W/statoverride"; echo 'root nogroup 755 /private/etc'; } > "$SO"
expect 1 unknown-group 'group nogroup is not in' check -r "$ROOT"
{ cat "$W/statoverride"; echo '#0 #0 755 private/etc'; } > "$SO"
expect 1 relative '^checkmodes: statoverride: bad line: #0 #0 755 private/etc$' check -r "$ROOT"
printf '%s' "$(cat "$W/statoverride")" > "$SO"
expect 1 no-newline 'no newline at the end' check -r "$ROOT"
{ cat "$W/statoverride"; echo '#0 #0 0755 /private/etc'; echo '#0 #0 0755 /private/etc'; } > "$SO"
expect 1 twice 'is there twice' check -r "$ROOT"
{ cat "$W/statoverride"; echo '#0 #0 rwx /private/etc'; } > "$SO"
expect 1 bad-mode 'bad mode' check -r "$ROOT"

cp "$W/statoverride" "$SO"
mv "$ROOT/private/etc/passwd" "$W/passwd"
ln -s "$W/passwd" "$ROOT/private/etc/passwd"
expect 1 confined '^checkmodes: etc/passwd leaves ' check -r "$ROOT"
rm "$ROOT/private/etc/passwd"
mv "$W/passwd" "$ROOT/private/etc/passwd"

{ cat "$W/statoverride"; echo '#1 #1 750 /private/var/msgs/bounds'; } > "$SO"
fr "$TOOLS/installroot.sh" "$ROOT" "$DEB"
cp "$SO" "$W/statoverride"
fr python3 "$TOOLS/mkhfs.py" "$ROOT" "$W/root.hfs" > /dev/null
volume_ok link
expect 0 link-installed '^777 1:1$' fr stat -c '%a %u:%g' "$ROOT/private/var/msgs/bounds"
expect 0 link-override '11 entries match' check -r "$ROOT"
sed 's|^.* /private/var/msgs/bounds$|#2 #1 750 /private/var/msgs/bounds|' "$W/statoverride" > "$SO"
expect 1 link-owner '^/private/var/msgs/bounds: volume lrwxrwxrwx 120777 1:1, statoverride lrwxrwxrwx 120777 2:1$' check -r "$ROOT"

cp "$W/statoverride" "$SO"
fr chown 2 "$ROOT/private/var/at/spool" "$ROOT/private/etc/passwd"
fr python3 "$TOOLS/mkhfs.py" "$ROOT" "$W/root.hfs" > /dev/null
volume_ok owner
expect 1 volume-owner '2 differences' check -r "$ROOT"
expect 1 volume-owner-at '^/private/var/at/spool: volume drwxr-xr-x 040755 2:0, statoverride drwxr-xr-x 040755 1:0$' check -r "$ROOT"
expect 1 volume-owner-etc '^/private/etc/passwd: volume -rw-r--r-- 100644 2:0, at-test -rw-r--r-- 100644 0:0$' check -r "$ROOT"

fr chown 1 "$ROOT/private/var/at/spool"
fr chown 0 "$ROOT/private/etc/passwd"
echo text > "$ROOT/private/var/at/a:b"
fr python3 "$TOOLS/mkhfs.py" -J "$ROOT" "$W/root.hfs" > /dev/null
volume_ok journaled
expect 0 journaled-tree 'volume holds the [0-9]* entries' check -r "$ROOT" -t
echo other > "$ROOT/private/var/at/a:b"
expect 1 tree-data '^/private/var/at/a:b: the volume.s data differs$' check -r "$ROOT" -t
exit "$FAILED"
