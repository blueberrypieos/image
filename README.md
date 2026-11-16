# image

The Blueberry Pie OS SD card images for the Raspberry Pi 4 and 5, built
from the packages in the apt repository at https://blueberrypieos.com/apt/.
There are two, with the same packages: one with an HFS+ root, one with a
ZFS root.

## The images

- MBR disk images, compressed with xz: 2 GiB for `-hfs`, 4 GiB for `-zfs`.
- Partition 1: FAT32, 256 MiB, labelled `PIEBOOT`. It holds the
  firmware, pieboot, `config.txt`, the kernel bundle and `cmdline.txt`.
- Partition 2 of `-hfs`: HFS+, case-sensitive and journaled, named
  "Blueberry Pie OS". It holds the root file system.
- Partition 2 of `-zfs`: the ZFS pool `pie`, of 3 GiB. The ZFS image needs
  2 GB of memory or more.
- The user `pie` is in `admin`, so it may use `sudo`. Its password is
  `blueberry`, and sshd accepts it from the first boot. Change it with
  `passwd` after the first login.
- Accounts are in OpenDirectory: opendirectoryd keeps them in
  `/var/db/dslocal`. `build.sh` writes pie's record there.
  `dscl` reads them, and root adds users with it.

## The ZFS image

The pool holds two kinds of dataset:

- **Roots**, `pie/root/N`: everything packages install, `/etc` included.
  The pool's `bootfs` names the root that boots.
- **Data sets**, `pie/data/NAME`, with the children `tmp`, `Users`,
  `Volumes`, `cores` and `local`: what the system writes, on
  `/private/var`, `/private/tmp`, `/Users`, `/Volumes`, `/cores` and
  `/usr/local`. The first is `pie/data/default`.

dpkg leaves the data paths out, and keeps its database in the root, in
`/usr/lib/blueberry-pie-os/dpkg`. At boot, the directories the installed
packages list there are made in the data set. So any data set runs on any
root: a snapshot of a data set taken before an update runs on the updated
root.

The root is read-write, and apt updates it in place. Before each apt run
the root is snapshotted, and `pie-boot rollback` goes back to the root as
it was before the last one.

`pie-seal` makes a sealed copy of the root, which is read-only, as the
root of the next soft reboot. On a sealed root, apt installs into a stage
on `/System/Volumes/Update`, and `softreboot` moves onto it: user space
restarts on the new root, without restarting the kernel. A new kernel
needs a reboot. `pie-unseal` goes back to a read-write root, also at the
next soft reboot.

`pie-data create NAME -u USER` makes an empty data set whose
administrator is USER, and `softreboot -d NAME` runs on it. `pie-data
snapshot` and `pie-data clone` keep and bring back data sets. `pie-boot`
lists the roots and sets the one that boots.

## Kernel messages

The kernel keeps its messages in a buffer in memory. `sudo dmesg` shows
them. They don't go to syslogd, so `/var/log/system.log` has none: the
kernel opens `/dev/klog` only when the boot argument
`atm_diagnostic_config` has the bit 0x20000000, and the image doesn't set
it.

To log kernel messages to `/var/log/system.log`, add
`atm_diagnostic_config=0x20000000` to the line in `cmdline.txt` on the
`PIEBOOT` partition, then reboot. Package updates don't change
`cmdline.txt`.

## Contents

The root has every package that is Essential or has Priority required,
important or standard. It also has the packages that `packages` names, one
per line, such as `rpi-firmware`, which has Priority optional. The ZFS
image also has the packages that `packages-zfs` names. Each comes with the
packages it depends on, at its newest version. The `.manifest` next to
each image lists them.

## Building

```
./build.sh [-r REPO_URL] [-k KEYRING] [-p PACKAGES] [-z PACKAGES] [-x DIR] [-o OUTDIR] VERSION
```

`-p` takes another list of packages in place of `packages`, and `-z` in
place of `packages-zfs`. `-x` names a directory of .deb files, which take
the place of the repository's packages of the same names or add to them.

It needs dpkg, fakeroot, mtools, dosfstools, fdisk, hfsprogs, xz-utils,
python3, git, sqv or gpgv, pie-makefs 2 or later and zdb from
zfsutils-linux. No root access, loop devices or mounts are needed.
Without git history, SOURCE_DATE_EPOCH must be set.

The root tree is made in one fakeroot session. The volume keeps each
file's mode, owner and group from its deb. `tools/checkmodes.py` checks
this for every entry of every deb, and the build fails on a difference.
A path that a maintainer script gave to `dpkg-statoverride` must have the
override's mode, owner and group instead. It also checks that the volume
holds exactly the root tree's files, data and links. Then fsck.hfsplus
checks the volume on a copy, and the build fails if it changes anything.
`tests/checkmodes.sh` tests these checks. It runs fsck.hfsplus on its own
volumes when hfsprogs is installed.

The ZFS image's root tree is installed with dpkg leaving out the data
paths, and the build fails if anything but dpkg's link is there. The data
set's tree is those paths of a whole install. The merged tree goes through
the same checks on an HFS+ volume made for that, before pie-makefs writes
the pool. zdb then checks the pool.

The repository's InRelease must be signed by a key in
`keys/blueberry-pie-os-archive-keyring.gpg`.

## Releases

A tag builds the images, attests them and releases:

- `blueberry-pie-os-rpi-VERSION-hfs.img.xz` and its `.manifest`;
- `blueberry-pie-os-rpi-VERSION-zfs.img.xz` and its `.manifest`;
- `SHA256SUMS`.

Write an image to an SD card with any image writer.

## A fallback for panics and failed boots

`docs/trial-boot.md` explains how to set up a fallback on a Pi: a second
system boots, and if it fails to boot, hangs or panics, the Pi falls back
to the system that works. The scripts are in `tests/pi`.
