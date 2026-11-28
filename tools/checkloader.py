#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
"""
Check an RK3566 loader before tools/mkimage.sh -l writes it at sector 64.

usage: checkloader.py LOADER

The sectors named here are the card's. LOADER must start with the
Rockchip boot header, RKNS, and be a whole number of sectors. It must hold
0xff in sectors 7168 to 7679, where Rockchip vendor storage lives. Its FIT
must start at sector 16384, where the GPT's uboot partition starts. It
must end before sector 24576. LOADER must be a regular file. Each broken
rule is printed, and the exit status is 1 if there is one.
"""
import os
import stat
import sys

SECTOR = 512
START = 64
VENDOR, VENDOR_END = 7168, 7680
FIT = 16384
END = 24576


def at(sector):
    return (sector - START) * SECTOR


def problems(data, size):
    if data[:4] != b"RKNS":
        yield "it does not start with the Rockchip boot header, RKNS"
    if size == 0 or size % SECTOR:
        yield "it is %d bytes, not a whole number of sectors" % size
    if START * SECTOR + size > END * SECTOR:
        yield "it does not end before sector %d" % END
    vendor = data[at(VENDOR):at(VENDOR_END)]
    if len(vendor) < at(VENDOR_END) - at(VENDOR):
        yield "it ends before sector %d" % VENDOR_END
    elif vendor.count(0xff) != len(vendor):
        yield "it does not hold 0xff in sectors %d to %d, where Rockchip vendor storage lives" % (
            VENDOR, VENDOR_END - 1)
    if data[at(FIT):at(FIT) + 4] != b"\xd0\x0d\xfe\xed":
        yield "it has no FIT at sector %d" % FIT


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: checkloader.py LOADER\n")
        return 2
    path = sys.argv[1]
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            os.close(fd)
            sys.stderr.write("checkloader: %s: not a regular file\n" % path)
            return 1
        with os.fdopen(fd, "rb") as f:
            size = st.st_size
            data = f.read(END * SECTOR)
    except OSError as e:
        sys.stderr.write("checkloader: %s: %s\n" % (path, e.strerror))
        return 1
    bad = list(problems(data, size))
    for p in bad:
        sys.stderr.write("checkloader: %s: %s\n" % (path, p))
    if not bad:
        print("checkloader: %s: an RK3566 loader for sector 64, %d bytes" % (path, size))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
