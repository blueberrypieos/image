#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
"""
Build a case-sensitive HFS+ volume image, an HFSX volume, from a
directory tree, without mounting anything.

usage: mkhfs.py [-n NAME] [-s SIZE_MB] [--uid N --gid N] [-J] [--seed TEXT] [-u UUID_FILE] SRC_DIR OUT.img

It supports directories, regular files and symbolic links. Each gets the
mode, owner and group that lstat gives it. Run it in the fakeroot session
that made SRC_DIR, resumed with fakeroot -i, to keep that session's modes
and owners. --uid and --gid give every entry that owner or group. -J
makes the volume journaled, as newfs_hfs -J does. A hard link becomes a
separate copy of its file. Extended attributes and resource forks are not
supported. Names are stored in decomposed Unicode, with each ":" as "/",
as the kernel stores them. Two names in a directory that are the same
when stored are an error. The layout follows TN1150, HFS Plus Volume
Format. build.sh checks the result with fsck.hfsplus.

The volume gets a random 64-bit ID, and so a UUID. --seed derives the ID
from TEXT instead. -u writes the UUID to UUID_FILE, for booting with
rd=uuid boot-uuid=UUID. With SOURCE_DATE_EPOCH set, the volume's dates are
that time, and no file's date is later.
"""
import argparse
import hashlib
import os
import stat
import struct
import time
import unicodedata

BLOCK = 4096
CATALOG_NODE = 8192
EXTENTS_NODE = 4096
ATTRIBUTES_NODE = 8192
ATTR_MAX_KEY = 266

ROOT_PARENT_ID = 1
ROOT_FOLDER_ID = 2
EXTENTS_FILE_ID = 3
CATALOG_FILE_ID = 4
FIRST_USER_ID = 16

FOLDER_RECORD = 1
FILE_RECORD = 2
FOLDER_THREAD = 3
FILE_THREAD = 4

LEAF_NODE = -1
INDEX_NODE = 0
HEADER_NODE = 1

FILE_THREAD_EXISTS = 0x0002
HAS_FOLDER_COUNT = 0x0010
VOLUME_UNMOUNTED = 1 << 8
VOLUME_JOURNALED = 1 << 13
JOURNAL_SIZE = 8 * 1024 * 1024
JI_JOURNAL_IN_FS = 0x1
JI_JOURNAL_NEED_INIT = 0x4
UF_NODUMP = 0x1
FINDER_INVISIBLE_LOCKED = 0x4000 | 0x1000
BT_BIG_KEYS = 0x2
BT_VARIABLE_INDEX_KEYS = 0x4
BINARY_COMPARE = 0xBC

HFS_EPOCH_DELTA = 2082844800


def hfs_time(t):
    return (int(t) + HFS_EPOCH_DELTA) & 0xffffffff


def hfs_name(name):
    return unicodedata.normalize("NFD", name.replace(":", "/"))


def uni_name(name):
    s = hfs_name(name)
    u = s.encode("utf-16-be")
    if len(u) // 2 > 255:
        raise ValueError("name too long: %r" % name)
    return struct.pack(">H", len(u) // 2) + u


def catalog_key(parent, name):
    body = struct.pack(">I", parent) + uni_name(name)
    return struct.pack(">H", len(body)) + body


def key_sort(parent, name):
    s = hfs_name(name).encode("utf-16-be")
    return (parent, [int.from_bytes(s[i:i + 2], "big") for i in range(0, len(s), 2)])


def bsd_info(uid, gid, mode):
    return struct.pack(">IIBBHI", uid, gid, 0, 0, mode, 0)


def fork_data(size, start, count, clump=0):
    ext = struct.pack(">II", start, count) if count else b"\0" * 8
    return struct.pack(">QII", size, clump, count) + ext + b"\0" * 56


class Node:
    def __init__(self, path, name, parent, cnid):
        self.path, self.name, self.parent, self.cnid = path, name, parent, cnid
        self.children = []
        self.data = b""
        self.start = 0
        self.blocks = 0


def scan(src, args):
    next_id = [FIRST_USER_ID]
    root = Node(src, args.name, ROOT_PARENT_ID, ROOT_FOLDER_ID)
    root.st = os.lstat(src)
    nodes = [root]

    def walk(dirnode):
        seen = {}
        for entry in sorted(os.listdir(dirnode.path)):
            p = os.path.join(dirnode.path, entry)
            key = hfs_name(entry)
            if key in seen:
                raise SystemExit("mkhfs: %s and %s have the same HFS+ name"
                                 % (os.path.join(dirnode.path, seen[key]), p))
            seen[key] = entry
            st = os.lstat(p)
            n = Node(p, entry, dirnode.cnid, next_id[0])
            next_id[0] += 1
            n.st = st
            if stat.S_ISDIR(st.st_mode):
                n.kind = "dir"
            elif stat.S_ISLNK(st.st_mode):
                n.kind = "link"
                n.data = os.readlink(p).encode()
            elif stat.S_ISREG(st.st_mode):
                n.kind = "file"
                with open(p, "rb") as f:
                    n.data = f.read()
            else:
                print("mkhfs: skipping %s: not a file, directory or link" % p)
                continue
            dirnode.children.append(n)
            nodes.append(n)
            if n.kind == "dir":
                walk(n)

    root.kind = "dir"
    walk(root)
    return nodes, next_id[0]


def node_bytes(size, kind, height, records, flink=0, blink=0):
    buf = bytearray(size)
    struct.pack_into(">IIbBHH", buf, 0, flink, blink, kind, height, len(records), 0)
    off = 14
    offsets = []
    for r in records:
        offsets.append(off)
        buf[off:off + len(r)] = r
        off += len(r)
    offsets.append(off)
    for i, o in enumerate(offsets):
        struct.pack_into(">H", buf, size - 2 * (i + 1), o)
    return bytes(buf)


def fits(records, size):
    return 14 + sum(len(r) for r in records) + 2 * (len(records) + 1) <= size


def header_node(size, depth, root, leaf_records, first_leaf, last_leaf, total, free,
                max_key, compare, attributes, used_nodes):
    hdr = struct.pack(">HIIIIHHIIHIBBI", depth, root, leaf_records, first_leaf, last_leaf,
                      size, max_key, total, free, 0, 0, 0, compare, attributes) + b"\0" * 64
    user = b"\0" * 128
    map_len = size - 14 - len(hdr) - len(user) - 2 * 4
    bitmap = bytearray(map_len)
    for n in range(used_nodes):
        bitmap[n // 8] |= 0x80 >> (n % 8)
    return node_bytes(size, HEADER_NODE, 0, [hdr, user, bytes(bitmap)])


def build_btree(size, leaf_records, max_key, compare, attributes, spare_nodes):
    nodes = {}
    next_node = [1]

    def new_node():
        n = next_node[0]
        next_node[0] += 1
        return n

    level = []
    cur = []
    for sk, key, rec in leaf_records:
        r = key + rec
        if cur and not fits([x[1] for x in cur] + [r], size):
            level.append(cur)
            cur = []
        cur.append((key, r))
    if cur:
        level.append(cur)
    leaf_nums = [new_node() for _ in level]
    for i, recs in enumerate(level):
        nodes[leaf_nums[i]] = (LEAF_NODE, 1, [r for _, r in recs],
                               leaf_nums[i + 1] if i + 1 < len(level) else 0,
                               leaf_nums[i - 1] if i > 0 else 0)
    first_leaf, last_leaf = (leaf_nums[0], leaf_nums[-1]) if leaf_nums else (0, 0)

    height = 1
    children = [(level[i][0][0], leaf_nums[i]) for i in range(len(level))]
    while len(children) > 1:
        height += 1
        groups, cur = [], []
        for key, child in children:
            r = key + struct.pack(">I", child)
            if cur and not fits([x[2] for x in cur] + [r], size):
                groups.append(cur)
                cur = []
            cur.append((key, child, r))
        groups.append(cur)
        nums = [new_node() for _ in groups]
        for i, g in enumerate(groups):
            nodes[nums[i]] = (INDEX_NODE, height, [x[2] for x in g],
                              nums[i + 1] if i + 1 < len(groups) else 0,
                              nums[i - 1] if i > 0 else 0)
        children = [(groups[i][0][0], nums[i]) for i in range(len(groups))]

    root = children[0][1] if children else 0
    depth = height if children else 0
    used = next_node[0]
    total = used + spare_nodes
    out = [header_node(size, depth, root, len(leaf_records), first_leaf, last_leaf,
                       total, total - used, max_key, compare, attributes, used)]
    for n in range(1, used):
        kind, h, recs, fl, bl = nodes[n]
        out.append(node_bytes(size, kind, h, recs, fl, bl))
    out.append(b"\0" * size * spare_nodes)
    return b"".join(out), total


def volume_uuid(volume_id):
    namespace = bytes.fromhex("B3E20F39F29211D697A400306543ECAC")
    u = bytearray(hashlib.md5(namespace + volume_id).digest())
    u[6] = 0x30 | (u[6] & 0x0F)
    u[8] = 0x80 | (u[8] & 0x3F)
    h = u.hex().upper()
    return "%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:])


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("-n", "--name", default="PIE")
    ap.add_argument("-s", "--size", type=int, default=0, help="image size in MB, by default the smallest that fits")
    ap.add_argument("--uid", type=int)
    ap.add_argument("--gid", type=int)
    ap.add_argument("--free", type=int, default=16, help="extra free space in MB, when -s is not given")
    ap.add_argument("-J", "--journal", action="store_true", help="with a journal")
    ap.add_argument("-u", "--uuid-file", help="write the volume UUID here")
    ap.add_argument("--seed", help="derive the volume ID from this text")
    ap.add_argument("src")
    ap.add_argument("out")
    args = ap.parse_args()

    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    clamp = int(epoch) if epoch else None
    now = hfs_time(clamp if clamp is not None else time.time())

    def date(t):
        return hfs_time(t if clamp is None else min(t, clamp))
    nodes, next_id = scan(args.src, args)

    def blocks_for(n):
        return (n + BLOCK - 1) // BLOCK

    data_blocks = sum(blocks_for(len(n.data)) for n in nodes)
    leaf_guess = sum(300 + 2 * len(n.name) for n in nodes) * 2
    cat_nodes_guess = leaf_guess // CATALOG_NODE + 16
    if args.size:
        total_blocks = args.size * 1024 * 1024 // BLOCK
    else:
        est = 2 + data_blocks + cat_nodes_guess * CATALOG_NODE // BLOCK + 64
        total_blocks = est + args.free * 1024 * 1024 // BLOCK
    alloc_blocks = blocks_for((total_blocks + 7) // 8)

    cursor = 1
    alloc_start = cursor
    cursor += alloc_blocks
    extents_nodes = 4
    extents_start = cursor
    extents_blocks = extents_nodes * EXTENTS_NODE // BLOCK
    cursor += extents_blocks
    attr_nodes = 8
    attr_start = cursor
    attr_blocks = attr_nodes * ATTRIBUTES_NODE // BLOCK
    cursor += attr_blocks

    jib_block = 0
    if args.journal:
        jib_block = cursor
        cursor += 1
        journal_start = cursor
        cursor += JOURNAL_SIZE // BLOCK
        root = nodes[0]
        for name, start, size in ((".journal", journal_start, JOURNAL_SIZE),
                                  (".journal_info_block", jib_block, BLOCK)):
            n = Node(None, name, ROOT_FOLDER_ID, next_id)
            next_id += 1
            n.kind = "journal"
            n.start, n.blocks, n.size = start, size // BLOCK, size
            root.children.append(n)
            nodes.append(n)

    records = []
    for n in nodes:
        if n.kind == "journal":
            dates = struct.pack(">IIIII", now, now, now, now, 0)
        else:
            mode = stat.S_IMODE(n.st.st_mode)
            uid = n.st.st_uid if args.uid is None else args.uid
            gid = n.st.st_gid if args.gid is None else args.gid
            dates = struct.pack(">IIIII", date(n.st.st_mtime), date(n.st.st_mtime),
                                date(n.st.st_mtime), date(n.st.st_atime), 0)
        if n.kind == "journal":
            n.rec_parts = (struct.pack(">hHII", FILE_RECORD, FILE_THREAD_EXISTS, 0, n.cnid) + dates
                           + struct.pack(">IIBBHI", 0, 0, 0, UF_NODUMP, stat.S_IFREG, 1)
                           + struct.pack(">4s4sH6x", b"jrnl", b"hfs+", FINDER_INVISIBLE_LOCKED)
                           + b"\0" * 16 + struct.pack(">II", 0, 0))
            thread_type = FILE_THREAD
        elif n.kind == "dir":
            subfolders = sum(1 for c in n.children if c.kind == "dir")
            n.rec = (struct.pack(">hHII", FOLDER_RECORD, HAS_FOLDER_COUNT, len(n.children), n.cnid)
                     + dates + bsd_info(uid, gid, stat.S_IFDIR | mode) + b"\0" * 16 + b"\0" * 16
                     + struct.pack(">II", 0, subfolders))
            thread_type = FOLDER_THREAD
        else:
            fmode = (stat.S_IFLNK if n.kind == "link" else stat.S_IFREG) | mode
            finder = (struct.pack(">II", 0x736C6E6B, 0x72686170) if n.kind == "link"
                      else b"\0" * 8) + b"\0" * 8
            n.rec_parts = (struct.pack(">hHII", FILE_RECORD, FILE_THREAD_EXISTS, 0, n.cnid) + dates
                           + bsd_info(uid, gid, fmode) + finder + b"\0" * 16
                           + struct.pack(">II", 0, 0))
            thread_type = FILE_THREAD
        thread = struct.pack(">hhI", thread_type, 0, n.parent) + uni_name(n.name)
        n.thread = (key_sort(n.cnid, ""), catalog_key(n.cnid, ""), thread)

    def catalog_records():
        out = []
        for n in nodes:
            if n.kind == "dir":
                rec = n.rec
            else:
                rec = (n.rec_parts + fork_data(getattr(n, "size", len(n.data)), n.start, n.blocks)
                       + fork_data(0, 0, 0))
            out.append((key_sort(n.parent, n.name), catalog_key(n.parent, n.name), rec))
            out.append(n.thread)
        out.sort(key=lambda r: r[0])
        return out

    spare = max(32, len(nodes) // 8)
    cat, cat_total = build_btree(CATALOG_NODE, catalog_records(), 516, BINARY_COMPARE,
                                 BT_BIG_KEYS | BT_VARIABLE_INDEX_KEYS, spare)
    catalog_start = cursor
    catalog_blocks = blocks_for(len(cat)) + 8
    cursor += catalog_blocks
    for n in nodes:
        if n.kind != "dir" and n.data:
            n.start = cursor
            n.blocks = blocks_for(len(n.data))
            cursor += n.blocks
    if cursor + 1 > total_blocks:
        raise SystemExit("mkhfs: image too small (need %d blocks)" % (cursor + 1))
    cat, cat_total2 = build_btree(CATALOG_NODE, catalog_records(), 516, BINARY_COMPARE,
                                  BT_BIG_KEYS | BT_VARIABLE_INDEX_KEYS, spare)
    assert cat_total2 == cat_total
    cat += b"\0" * (catalog_blocks * BLOCK - len(cat))
    cat_total = catalog_blocks * BLOCK // CATALOG_NODE
    used = cat_total2 - spare
    cat = header_node(CATALOG_NODE, *struct.unpack_from(">HIIII", cat, 14),
                      cat_total, cat_total - used, 516, BINARY_COMPARE,
                      BT_BIG_KEYS | BT_VARIABLE_INDEX_KEYS, used) + cat[CATALOG_NODE:]

    ext, ext_total = build_btree(EXTENTS_NODE, [], 10, 0, BT_BIG_KEYS, extents_nodes - 1)
    attr, attr_total = build_btree(ATTRIBUTES_NODE, [], ATTR_MAX_KEY, 0,
                                   BT_BIG_KEYS | BT_VARIABLE_INDEX_KEYS, attr_nodes - 1)

    used_blocks = cursor + 1
    bitmap = bytearray(alloc_blocks * BLOCK)
    for b in list(range(cursor)) + [total_blocks - 1]:
        bitmap[b // 8] |= 0x80 >> (b % 8)
    free_blocks = total_blocks - used_blocks

    files = sum(1 for n in nodes if n.kind != "dir")
    folders = sum(1 for n in nodes if n.kind == "dir") - 1

    if args.journal:
        vh = struct.pack(">2sHIII", b"HX", 5, VOLUME_UNMOUNTED | VOLUME_JOURNALED,
                         0x4846534A, jib_block)
    else:
        vh = struct.pack(">2sHIII", b"HX", 5, VOLUME_UNMOUNTED, 0x31302E30, 0)
    vh += struct.pack(">IIII", now, now, 0, now)
    vh += struct.pack(">IIIIIIIIIIQ", files, folders, BLOCK, total_blocks, free_blocks,
                      cursor, BLOCK, BLOCK, next_id, 1, 1)
    volume_id = hashlib.sha256(args.seed.encode()).digest()[:8] if args.seed else os.urandom(8)
    vh += b"\0" * 24 + volume_id
    vh += fork_data(alloc_blocks * BLOCK, alloc_start, alloc_blocks)
    vh += fork_data(extents_blocks * BLOCK, extents_start, extents_blocks)
    vh += fork_data(catalog_blocks * BLOCK, catalog_start, catalog_blocks)
    vh += fork_data(attr_blocks * BLOCK, attr_start, attr_blocks, attr_blocks * BLOCK)
    vh += fork_data(0, 0, 0)
    assert len(vh) == 512

    size = total_blocks * BLOCK
    with open(args.out, "wb") as out:
        out.truncate(size)
        out.seek(1024)
        out.write(vh)
        out.seek(alloc_start * BLOCK)
        out.write(bitmap)
        if args.journal:
            out.seek(jib_block * BLOCK)
            out.write(struct.pack(">I32xQQ", JI_JOURNAL_IN_FS | JI_JOURNAL_NEED_INIT,
                                  journal_start * BLOCK, JOURNAL_SIZE))
        out.seek(extents_start * BLOCK)
        out.write(ext)
        out.seek(attr_start * BLOCK)
        out.write(attr)
        out.seek(catalog_start * BLOCK)
        out.write(cat)
        for n in nodes:
            if n.kind != "dir" and n.data:
                out.seek(n.start * BLOCK)
                out.write(n.data)
        out.seek(size - 1024)
        out.write(vh)
    uuid = volume_uuid(volume_id)
    if args.uuid_file:
        with open(args.uuid_file, "w") as f:
            f.write(uuid + "\n")
    print("mkhfs: %s: %d files, %d folders, %d of %d blocks used, UUID %s" %
          (args.out, files, folders + 1, used_blocks, total_blocks, uuid))


if __name__ == "__main__":
    main()
