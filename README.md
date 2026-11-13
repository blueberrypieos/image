# image

The Blueberry Pie OS SD card image for the Raspberry Pi 4 and 5, built
from the packages in the apt repository at https://blueberrypieos.com/apt/.

## The image

- An MBR disk image of 2 GiB, compressed with xz.
- Partition 1: FAT32, 256 MiB, labelled `PIEBOOT`. It holds the
  firmware, pieboot, `config.txt`, the kernel bundle and `cmdline.txt`.
- Partition 2: HFS+, case-sensitive and journaled, named "Blueberry Pie OS".
  It holds the root file system.
- The user `pie` is in `admin`, so it may use `sudo`. Its password is
  `blueberry`, and sshd accepts it from the first boot. Change it with
  `passwd` after the first login.
- Accounts are in OpenDirectory: opendirectoryd keeps them in
  `/var/db/dslocal`. `build.sh` writes pie's record there.
  `dscl` reads them, and root adds users with it.

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
per line, such as `rpi-firmware`, which has Priority optional. Each comes
with the packages it depends on, at its newest version. The `.manifest`
next to the image lists them.

## Building

```
./build.sh [-r REPO_URL] [-k KEYRING] [-p PACKAGES] [-o OUTDIR] VERSION
```

`-p` takes another list of packages in place of `packages`.

It needs dpkg, fakeroot, mtools, dosfstools, fdisk, hfsprogs, xz-utils,
python3, git, and sqv or gpgv. No root access, loop devices or mounts are
needed. Without git history, SOURCE_DATE_EPOCH must be set.

The root tree is made in one fakeroot session. The volume keeps each
file's mode, owner and group from its deb. `tools/checkmodes.py` checks
this for every entry of every deb, and the build fails on a difference.
A path that a maintainer script gave to `dpkg-statoverride` must have the
override's mode, owner and group instead. It also checks that the volume
holds exactly the root tree's files, data and links. Then fsck.hfsplus
checks the volume on a copy, and the build fails if it changes anything.
`tests/checkmodes.sh` tests these checks. It runs fsck.hfsplus on its own
volumes when hfsprogs is installed.

The repository's InRelease must be signed by a key in
`keys/blueberry-pie-os-archive-keyring.gpg`.

## Releases

A tag builds the image, attests it and releases:

- `blueberry-pie-os-rpi-VERSION.img.xz`;
- `blueberry-pie-os-rpi-VERSION.manifest`;
- `SHA256SUMS`.

Write the image to an SD card with any image writer.
