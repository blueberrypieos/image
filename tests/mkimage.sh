#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
# Usage: mkimage.sh
set -euo pipefail
[[ $# == 0 ]] || { sed -n '4p' "$0" >&2; exit 2; }
TOOLS=$(cd -- "$(dirname -- "$0")/../tools" && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export MTOOLS_SKIP_CHECK=1 SOURCE_DATE_EPOCH=1700000000
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
py() {
    python3 - "$@" <<'PY'
import os, struct, sys
mode, img = sys.argv[1], sys.argv[2]
f = open(img, 'rb')
head = f.read(32768 * 512)
mbr = head[:512]
parts = [struct.unpack_from('<B3sB3sII', mbr, 446 + 16 * i) for i in range(4)]
if mode == 'layout':
    loader = open(sys.argv[3], 'rb').read() if len(sys.argv) > 3 else b''
    print('mbr: %s' % ('yes' if mbr[510:] == b'\x55\xaa' else 'no'))
    for i, (flag, _, kind, _, start, count) in enumerate(parts):
        if kind:
            print('partition %d: type 0x%02x, flag 0x%02x, sectors %d to %d' % (i + 1, kind, flag, start, start + count - 1))
    print('entries: %d' % sum(1 for p in parts if p[2]))
    print('0xee entries: %d' % sum(1 for p in parts if p[2] == 0xee))
    at = 64 * 512
    rest = head[34 * 512:at] + head[at + len(loader):]
    print('gap: %s' % ('zero' if rest.count(0) == len(rest) else 'not zero'))
    print('head: %s' % ('zero' if head[512:34 * 512].count(0) == 33 * 512 else 'not zero'))
    print('loader: %s' % ('in place' if head[at:at + len(loader)] == loader else 'missing'))
    print('image: %d bytes' % os.path.getsize(img))
    end = max(p[4] + p[5] for p in parts if p[2])
    print('after the last partition: %d sectors' % (os.path.getsize(img) // 512 - end))
elif mode == 'gpt':
    import uuid, zlib
    n = os.path.getsize(img) // 512
    f.seek((n - 2048) * 512)
    tail = f.read(2048 * 512)
    end = max(p[4] + p[5] for p in parts if p[2])
    f.seek(end * 512)
    between = f.read((n - 2048 - end) * 512)
    if head[512:1024][:8] != b'EFI PART':
        print('gpt: none')
        print('tail: %s' % ('zero' if tail.count(0) == len(tail) and between.count(0) == len(between) else 'not zero'))
        sys.exit(0)

    def check(h, my, alt, at, ents):
        hh = bytearray(h[:92])
        hh[16:20] = bytes(4)
        assert struct.unpack_from('<8sIII', h, 0) == (b'EFI PART', 0x10000, 92, zlib.crc32(hh)), 'header'
        assert struct.unpack_from('<IQQQQ', h, 20) == (0, my, alt, 34, n - 34), 'LBAs'
        assert struct.unpack_from('<QIII', h, 72) == (at, 128, 128, zlib.crc32(ents)), 'entries'
        assert h[92:].count(0) == 420, 'header padding'
        return str(uuid.UUID(bytes_le=bytes(h[56:72])))
    ents = head[1024:1024 + 16384]
    disk = check(head[512:1024], 1, n - 1, 2, ents)
    print('gpt: primary valid')
    assert tail[-512 - 16384:-512] == ents, 'backup entries'
    assert check(tail[-512:], n - 1, 1, n - 33, ents) == disk
    print('gpt: backup valid, at the last sector')
    t, u = (str(uuid.UUID(bytes_le=bytes(ents[i:i + 16]))) for i in (0, 16))
    first, last, attr = struct.unpack_from('<QQQ', ents, 32)
    name = ents[56:128].decode('utf-16-le').rstrip('\0')
    print('gpt: entry 1: %s %d to %d, attributes %d, type %s, guid %s' % (name, first, last, attr, t, u))
    print('gpt: other entries: %s' % ('zero' if ents[128:].count(0) == len(ents) - 128 else 'used'))
    print('gpt: disk %s' % disk)
    print('tail: %s' % ('zero' if tail[:-33 * 512].count(0) == len(tail) - 33 * 512 and between.count(0) == len(between) else 'not zero'))
elif mode == 'fat':
    start, count = parts[0][4], parts[0][5]
    f.seek(start * 512)
    bpb = f.read(512)
    total = struct.unpack_from('<I', bpb, 32)[0]
    print('fat: %d sectors per cluster' % bpb[13])
    print('fat: %s' % ('fills its partition' if count - 2048 < total <= count else '%d of %d sectors' % (total, count)))
elif mode == 'root':
    root = open(sys.argv[3], 'rb').read()
    f.seek(parts[1][4] * 512)
    print('root: %s' % ('same' if f.read(len(root)) == root else 'differs'))
elif mode == 'diff':
    other = open(sys.argv[3], 'rb')
    size = os.path.getsize(img)
    skip = [(64 * 512, 64 * 512 + os.path.getsize(sys.argv[4])), (512, 34 * 512), (size - 33 * 512, size)]
    f.seek(0)
    pos = 0
    same = size == os.path.getsize(sys.argv[3])
    while same:
        a, b = f.read(1 << 20), other.read(1 << 20)
        if not a and not b:
            break
        if a != b:
            a, b = bytearray(a), bytearray(b)
            for lo, hi in skip:
                s, e = max(lo - pos, 0), min(hi - pos, len(a))
                if s < e:
                    a[s:e] = bytes(e - s)
                    b[s:e] = bytes(e - s)
            same = a == b
        pos += len(a)
    print('images: %s' % ('the same but for the loader and the GPT' if same else 'differ'))
PY
}
fsck_fat() {
    dd if="$1" of="$W/fat.img" bs=512 skip=32768 count=1048576 conv=sparse status=none
    fsck.vfat -n "$W/fat.img"
}

mkdir -p "$W/boot/overlays"
echo pieboot > "$W/boot/pieboot.bin"
echo overlay > "$W/boot/overlays/a.dtbo"
head -c 5000000 /dev/urandom > "$W/root.img"
dd if=/dev/zero of="$W/root.img" bs=512 seek=100 count=50 conv=notrunc status=none
dd if=/dev/zero of="$W/root.img" bs=512 seek=9764 count=1 conv=notrunc status=none
mk() { "$TOOLS/mkimage.sh" -B "$W/boot" -r "$W/root.img" -t bf -a zfs_boot=pie "$@"; }

expect 0 build '^image: ' mk -o "$W/a.img"
expect 0 mbr '^mbr: yes$' py layout "$W/a.img"
expect 0 fat-entry '^partition 1: type 0x0c, flag 0x80, sectors 32768 to 1081343$' py layout "$W/a.img"
expect 0 root-entry '^partition 2: type 0xbf, flag 0x00, sectors 1081344 to 1091109$' py layout "$W/a.img"
expect 0 gap-zero '^gap: zero$' py layout "$W/a.img"
expect 0 head-zero '^head: zero$' py layout "$W/a.img"
expect 0 entries '^entries: 2$' py layout "$W/a.img"
expect 0 image-size '^image: 559939584 bytes$' py layout "$W/a.img"
expect 0 tail-size '^after the last partition: 2522 sectors$' py layout "$W/a.img"
expect 0 no-gpt '^gpt: none$' py gpt "$W/a.img"
expect 0 no-gpt-tail '^tail: zero$' py gpt "$W/a.img"
expect 0 root-data '^root: same$' py root "$W/a.img" "$W/root.img"
expect 0 fat-size '^fat: fills its partition$' py fat "$W/a.img"
expect 0 fat-cluster '^fat: 8 sectors per cluster$' py fat "$W/a.img"
expect 0 fat-label 'PIEBOOT' mlabel -i "$W/a.img@@16777216" -s ::
expect 0 fat-cmdline '^zfs_boot=pie$' mtype -i "$W/a.img@@16777216" ::/cmdline.txt
expect 0 fat-dir '^overlay$' mtype -i "$W/a.img@@16777216" ::/overlays/a.dtbo
expect 0 fat-fsck ' clusters$' fsck_fat "$W/a.img"

head -c 4000000 /dev/urandom > "$W/loader.bin"
dd if=/dev/zero of="$W/loader.bin" bs=512 seek=10 count=10 conv=notrunc status=none
expect 0 loader-build '^image: ' mk -o "$W/b.img" -l "$W/loader.bin"
expect 0 loader-placed '^loader: in place$' py layout "$W/b.img" "$W/loader.bin"
expect 0 loader-gap '^gap: zero$' py layout "$W/b.img" "$W/loader.bin"
expect 0 loader-only '^images: the same but for the loader and the GPT$' py diff "$W/a.img" "$W/b.img" "$W/loader.bin"
expect 0 loader-no-ee '^0xee entries: 0$' py layout "$W/b.img" "$W/loader.bin"
expect 0 loader-mbr-entries '^entries: 2$' py layout "$W/b.img" "$W/loader.bin"
expect 0 gpt-primary '^gpt: primary valid$' py gpt "$W/b.img"
expect 0 gpt-backup '^gpt: backup valid, at the last sector$' py gpt "$W/b.img"
expect 0 gpt-entry '^gpt: entry 1: uboot 16384 to 24575, attributes 0, type a60b0000-0000-4c7e-8000-015e00004db7, guid 7d0d0b55-3a81-51a3-8d9a-f5879dced4ce$' py gpt "$W/b.img"
expect 0 gpt-one-entry '^gpt: other entries: zero$' py gpt "$W/b.img"
expect 0 gpt-disk '^gpt: disk 9aca35a7-0f48-51bf-85e1-ce97d9283284$' py gpt "$W/b.img"
expect 0 gpt-tail '^tail: zero$' py gpt "$W/b.img"
expect 0 gpt-sfdisk-dos '^label: dos$' sfdisk -d "$W/b.img"
expect 0 gpt-sfdisk-fat 'start=       32768, size=     1048576, type=c, bootable$' sfdisk -d "$W/b.img"
expect 0 loader-same-size '^image: 559939584 bytes$' py layout "$W/b.img" "$W/loader.bin"
expect 0 loader-again '^image: ' mk -o "$W/b2.img" -l "$W/loader.bin"
expect 0 loader-reproducible '^same$' sh -c 'cmp -- "$1" "$2" && echo same' sh "$W/b.img" "$W/b2.img"
head -c $(( (24576 - 64) * 512 )) /dev/urandom > "$W/loader-max.bin"
expect 0 loader-max '^image: ' mk -o "$W/c.img" -l "$W/loader-max.bin"
expect 0 loader-max-placed '^loader: in place$' py layout "$W/c.img" "$W/loader-max.bin"
expect 0 loader-max-gap '^gap: zero$' py layout "$W/c.img" "$W/loader-max.bin"
expect 0 loader-max-gpt '^gpt: backup valid, at the last sector$' py gpt "$W/c.img"
expect 0 loader-max-fat '^zfs_boot=pie$' mtype -i "$W/c.img@@16777216" ::/cmdline.txt
printf x >> "$W/loader-max.bin"
expect 1 loader-too-big 'does not end before sector 24576' mk -o "$W/d.img" -l "$W/loader-max.bin"
ln -s "$W/loader-max.bin" "$W/loader-link.bin"
expect 1 loader-too-big-link 'does not end before sector 24576' mk -o "$W/d.img" -l "$W/loader-link.bin"
expect 1 loader-missing '^mkimage.sh: no loader ' mk -o "$W/d.img" -l "$W/none.bin"
expect 1 loader-no-image 'No such file' ls "$W/d.img"
ln -s "$W/root.img" "$W/root-link.img"
expect 0 root-link-build '^image: ' "$TOOLS/mkimage.sh" -B "$W/boot" -r "$W/root-link.img" -t bf -a zfs_boot=pie -o "$W/e.img"
expect 0 root-link-entry '^partition 2: type 0xbf, flag 0x00, sectors 1081344 to 1091109$' py layout "$W/e.img"
expect 0 root-link-data '^root: same$' py root "$W/e.img" "$W/root.img"
head -c 2097152 /dev/urandom > "$W/root-mib.img"
expect 0 root-mib-build '^image: ' "$TOOLS/mkimage.sh" -B "$W/boot" -r "$W/root-mib.img" -t bf -a zfs_boot=pie -o "$W/f.img"
expect 0 root-mib-entry '^partition 2: type 0xbf, flag 0x00, sectors 1081344 to 1085439$' py layout "$W/f.img"
expect 0 root-mib-size '^image: 556793856 bytes$' py layout "$W/f.img"
expect 0 root-mib-tail '^after the last partition: 2048 sectors$' py layout "$W/f.img"
expect 0 root-mib-gpt-build '^image: ' "$TOOLS/mkimage.sh" -B "$W/boot" -r "$W/root-mib.img" -t bf -a zfs_boot=pie -o "$W/h.img" -l "$W/loader.bin"
expect 0 root-mib-gpt-tail '^after the last partition: 2048 sectors$' py layout "$W/h.img" "$W/loader.bin"
expect 0 root-mib-gpt-backup '^gpt: backup valid, at the last sector$' py gpt "$W/h.img"
expect 0 root-mib-gpt-data '^root: same$' py root "$W/h.img" "$W/root-mib.img"
expect 1 usage '^# Needs dosfstools' "$TOOLS/mkimage.sh" -o "$W/g.img"
exit "$FAILED"
