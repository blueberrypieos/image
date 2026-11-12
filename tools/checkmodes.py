#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
"""
Check that an HFS+ volume gives every file of some debs the debs' type,
mode, owner and group.

usage: checkmodes.py [-r ROOT [-t]] VOLUME.hfs DEB...

Each entry of each deb's data archive is looked up on the volume, through
the volume's symbolic links, as dpkg finds it. A directory entry may find a
symbolic link to a directory, as dpkg keeps those. A hard link is checked
against the entry it links to. Each difference is printed, and so is each
path that two debs give different attributes. The exit status is 1 if
there is either.

-r names the root tree the volume was made from. An override that
dpkg-statoverride recorded in ROOT/private/var/lib/dpkg/statoverride gives
its path's mode, owner and group in place of the debs'. Its names are
looked up in ROOT/etc/passwd and ROOT/etc/group. Its path must be an entry's
name, as dpkg compares them: leading / and ./ are dropped, and nothing else
is changed. An override for a path that no deb has is an error. A symbolic
link keeps its mode, as dpkg gives it only the owner and group.

-t also checks that the volume holds exactly the entries of ROOT, with the
same types, file data and link targets. A journaled volume may also have
its two journal files.
"""
import io
import os
import re
import stat
import struct
import subprocess
import sys
import tarfile
import unicodedata

ROOT_FOLDER_ID = 2
FOLDER_RECORD = 1
FILE_RECORD = 2
LEAF_NODE = -1
VOLUME_JOURNALED = 1 << 13


def die(msg):
    sys.exit("checkmodes: " + msg)


class Volume:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.f.seek(1024)
        vh = self.f.read(512)
        if vh[:2] not in (b"H+", b"HX"):
            die("%s: not an HFS+ volume" % path)
        self.block = struct.unpack_from(">I", vh, 40)[0]
        self.journaled = bool(struct.unpack_from(">I", vh, 4)[0] & VOLUME_JOURNALED)
        catalog = self.fork(vh[272:352])
        node_size = struct.unpack_from(">H", catalog, 32)[0]
        first_leaf = struct.unpack_from(">I", catalog, 24)[0]
        self.children = {}
        self.entries = {}
        self.data = {}
        n = first_leaf
        while n:
            node = catalog[n * node_size:(n + 1) * node_size]
            flink, _, kind, _, count = struct.unpack_from(">IIbBH", node, 0)
            if kind != LEAF_NODE:
                die("catalog node %d is not a leaf" % n)
            for i in range(count):
                off = struct.unpack_from(">H", node, node_size - 2 * (i + 1))[0]
                self.record(node, off)
            n = flink
        self.parents = {c: p for p, kids in self.children.items() for c in kids.values()}

    def fork(self, fd):
        size, _, total = struct.unpack_from(">QII", fd, 0)
        out, blocks = [], 0
        for i in range(8):
            start, count = struct.unpack_from(">II", fd, 16 + 8 * i)
            if count:
                self.f.seek(start * self.block)
                out.append(self.f.read(count * self.block))
                blocks += count
        if blocks != total:
            die("a fork has extents in the overflow file")
        return b"".join(out)[:size]

    def record(self, node, off):
        key_len, parent, name_len = struct.unpack_from(">HIH", node, off)
        name = node[off + 8:off + 8 + 2 * name_len].decode("utf-16-be").replace("/", ":")
        rec = off + 2 + key_len
        kind = struct.unpack_from(">h", node, rec)[0]
        if kind not in (FOLDER_RECORD, FILE_RECORD):
            return
        cnid = struct.unpack_from(">I", node, rec + 8)[0]
        uid, gid, _, _, mode = struct.unpack_from(">IIBBH", node, rec + 32)
        target = None
        if kind == FILE_RECORD and stat.S_ISLNK(mode):
            target = self.fork(node[rec + 88:rec + 168]).decode()
        elif kind == FILE_RECORD:
            self.data[cnid] = node[rec + 88:rec + 168]
        self.entries[cnid] = (mode, uid, gid, target)
        siblings = self.children.setdefault(parent, {})
        if name in siblings:
            die("%s: two catalog records for %r in folder %d" % (self.f.name, name, parent))
        siblings[name] = cnid

    def lookup(self, path, follow_dir_link=False):
        hops = [0]

        def walk(cur, names, follow):
            for i, name in enumerate(names):
                last = i == len(names) - 1
                if name in ("", "."):
                    continue
                if name == "..":
                    if cur != ROOT_FOLDER_ID:
                        cur = self.parents.get(cur, ROOT_FOLDER_ID)
                    continue
                nxt = self.children.get(cur, {}).get(unicodedata.normalize("NFD", name))
                if nxt is None:
                    return None
                mode, _, _, target = self.entries[nxt]
                if stat.S_ISLNK(mode) and (not last or follow):
                    hops[0] += 1
                    if hops[0] > 32:
                        return None
                    base = ROOT_FOLDER_ID if target.startswith("/") else cur
                    dest = walk(base, target.split("/"), True)
                    if not last:
                        if dest is None:
                            return None
                        nxt = dest
                    elif dest is not None and stat.S_ISDIR(self.entries[dest][0]):
                        nxt = dest
                cur = nxt
            return cur

        return walk(ROOT_FOLDER_ID, path, follow_dir_link)


def same_tree(vol, root):
    def fail(e):
        die("%s: %s" % (e.filename, e.strerror))

    bad, matched = 0, set()
    for top, dirs, files in os.walk(root, onerror=fail):
        dirs.sort()
        rel = os.path.relpath(top, root)
        parent = vol.lookup([] if rel == "." else rel.split("/"))
        for name in sorted(dirs + files):
            p = os.path.join(top, name)
            path = os.path.normpath(os.path.join(rel, name))
            cnid = vol.children.get(parent, {}).get(unicodedata.normalize("NFD", name))
            if cnid is None:
                print("/%s: in the root, not on the volume" % path)
                bad += 1
                continue
            if cnid in matched:
                print("/%s: another name in the root has the same volume entry" % path)
                bad += 1
                continue
            matched.add(cnid)
            st = os.lstat(p)
            mode, _, _, target = vol.entries[cnid]
            if stat.S_IFMT(mode) != stat.S_IFMT(st.st_mode):
                print("/%s: a different type on the volume" % path)
                bad += 1
            elif stat.S_ISLNK(mode) and target != os.readlink(p):
                print("/%s: the volume's link target differs" % path)
                bad += 1
            elif stat.S_ISREG(mode):
                with open(p, "rb") as f:
                    if vol.fork(vol.data[cnid]) != f.read():
                        print("/%s: the volume's data differs" % path)
                        bad += 1
    rest = set(vol.entries) - matched - {ROOT_FOLDER_ID}
    if vol.journaled:
        for name in (".journal", ".journal_info_block"):
            cnid = vol.children.get(ROOT_FOLDER_ID, {}).get(name)
            if cnid in rest and stat.S_ISREG(vol.entries[cnid][0]):
                rest.discard(cnid)
    if rest:
        print("the volume has %d entries that the root does not" % len(rest))
        bad += 1
    return bad, len(matched)


def tar_type(m):
    if m.isdir():
        return stat.S_IFDIR
    if m.issym():
        return stat.S_IFLNK
    if m.isreg():
        return stat.S_IFREG
    die("%s: unsupported entry type" % m.name)


def dpkg_name(name):
    while name.startswith("/") or name.startswith("./"):
        name = name[1:]
    return name


def deb_entries(deb):
    tar = subprocess.run(["dpkg-deb", "--fsys-tarfile", deb], check=True,
                         stdout=subprocess.PIPE).stdout
    members = tarfile.open(fileobj=io.BytesIO(tar)).getmembers()
    by_name = {os.path.normpath(m.name): m for m in members}
    out = []
    for m in members:
        src, seen = m, set()
        while src is not None and src.islnk():
            if src.name in seen:
                die("%s: %s is in a hard-link loop" % (deb, m.name))
            seen.add(src.name)
            src = by_name.get(os.path.normpath(src.linkname))
        if src is None:
            die("%s: %s links to a missing entry" % (deb, m.name))
        out.append((os.path.normpath(m.name), tar_type(src) | stat.S_IMODE(src.mode),
                    src.uid, src.gid, dpkg_name(m.name)))
    return out


def in_root(root, path):
    top = os.path.realpath(root)
    real = os.path.realpath(os.path.join(top, path))
    if os.path.commonpath([real, top]) != top:
        die("%s leaves %s" % (path, root))
    return real


def ids(root, path):
    out = {}
    try:
        with open(in_root(root, path)) as f:
            for line in f:
                fields = line.rstrip("\n").split(":")
                if len(fields) > 2 and fields[0] and fields[2].isdigit():
                    out.setdefault(fields[0], int(fields[2]))
    except OSError as e:
        die("%s: %s" % (path, e.strerror))
    return out


def overrides(root):
    path = in_root(root, "private/var/lib/dpkg/statoverride")
    if not os.path.exists(path):
        return {}
    tables = {}

    def resolve(name, what, file):
        if re.fullmatch("#[0-9]+", name):
            return int(name[1:])
        if file not in tables:
            tables[file] = ids(root, file)
        if name not in tables[file]:
            die("statoverride: %s %s is not in the root's /%s" % (what, name, file))
        return tables[file][name]

    out = {}
    with open(path) as f:
        text = f.read()
    if text and not text.endswith("\n"):
        die("statoverride: no newline at the end")
    for line in text.split("\n")[:-1]:
        fields = line.split(" ", 3)
        if len(fields) != 4 or not fields[3].startswith("/"):
            die("statoverride: bad line: %s" % line)
        user, group, mode, name = fields
        if not re.fullmatch("[0-7]{1,4}", mode):
            die("statoverride: bad mode for %s" % name)
        key = dpkg_name(name)
        if key in out:
            die("statoverride: %s is there twice" % name)
        out[key] = (int(mode, 8), resolve(user, "user", "etc/passwd"),
                    resolve(group, "group", "etc/group"))
    return out


def show(mode, uid, gid):
    return "%s %06o %d:%d" % (stat.filemode(mode), mode, uid, gid)


def main():
    args = sys.argv[1:]
    root = None
    if args[:1] == ["-r"] and len(args) > 1:
        root, args = args[1], args[2:]
    tree = bool(root) and args[:1] == ["-t"]
    if tree:
        args = args[1:]
    if len(args) < 2 or args[0].startswith("-"):
        sys.exit(__doc__.strip().split("\n\n")[1])
    vol = Volume(args[0])
    want = {}
    names = {}
    bad = 0
    for deb in args[1:]:
        pkg = os.path.basename(deb).split("_")[0]
        for path, mode, uid, gid, name in deb_entries(deb):
            names[name] = path
            got = want.setdefault(path, (mode, uid, gid, pkg))
            if got[:3] != (mode, uid, gid):
                print("%s: %s gives %s, %s gives %s" % (path, got[3], show(*got[:3]),
                                                        pkg, show(mode, uid, gid)))
                bad += 1
    for name, (mode, uid, gid) in sorted(overrides(root).items() if root else ()):
        if name not in names:
            print("/%s: statoverride has it, no deb does" % name)
            bad += 1
            continue
        path = names[name]
        old = want[path][0]
        if stat.S_ISLNK(old):
            mode = stat.S_IMODE(old)
        want[path] = (stat.S_IFMT(old) | mode, uid, gid, "statoverride")
    for path in sorted(want):
        mode, uid, gid, pkg = want[path]
        names = [] if path == "." else path.split("/")
        cnid = vol.lookup(names, stat.S_ISDIR(mode))
        if cnid is None:
            print("/%s: missing (%s)" % (path, pkg))
            bad += 1
            continue
        vmode, vuid, vgid, _ = vol.entries[cnid]
        if (vmode, vuid, vgid) != (mode, uid, gid):
            print("/%s: volume %s, %s %s" % (path, show(vmode, vuid, vgid), pkg,
                                             show(mode, uid, gid)))
            bad += 1
    if bad:
        sys.exit("checkmodes: %d differences in %d entries" % (bad, len(want)))
    print("checkmodes: %d entries match" % len(want))
    if tree:
        bad, count = same_tree(vol, root)
        if bad:
            sys.exit("checkmodes: the volume differs from %s in %d places" % (root, bad))
        print("checkmodes: the volume holds the %d entries of %s" % (count, root))


if __name__ == "__main__":
    main()
