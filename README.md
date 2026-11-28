# image

The Blueberry Pie OS SD card images, built from the packages in the apt
repository at https://blueberrypieos.com/apt/. There are two, with the
same packages: one with an HFS+ root, one with a ZFS root. Both boot the
Raspberry Pi 4 and 5. The `-zfs` image also boots the Anbernic
RG353V from its first card slot, TF1. The `-hfs` image is for the
Raspberry Pi only. Boards added later boot the `-zfs` image.

## The images

- MBR disk images of 3601 MiB, compressed with xz.
- The first 16 MiB hold the MBR, then room up to partition 1 for the
  loader of a board whose boot ROM reads it from sector 64, such as the
  RK3566. In the `-hfs` image they are zeros after the MBR.
  `tools/mkimage.sh -l` writes the loader there, and a GPT for the
  loader on the RG353V's eMMC: one partition, uboot, at sectors 16384 to
  24575, where the loader's FIT starts. Its backup is in the image's
  last 33 sectors. The MBR has no 0xEE entry, so PIE, U-Boot and Linux
  read only the MBR.
- The `-zfs` image holds that loader and GPT. The loader is
  u-boot-rk3566's `u-boot-rockchip.bin`: U-Boot for the RK3566, with
  BL31 and the DDR init firmware. That firmware is Rockchip's, and
  non-free. The Raspberry Pi firmware reads the MBR and the FAT. Don't
  let a partitioning tool rewrite the GPT of a `-zfs` card. gdisk asks
  whether to use the MBR or the GPT. If you choose the GPT and write,
  it replaces the MBR, and the FAT and the root are lost.
- Partition 1: FAT32, 512 MiB, labelled `PIEBOOT`, from sector 32768. It
  holds the firmware, pieboot, `config.txt`, the kernel bundle and
  `cmdline.txt`. It also holds U-Boot's `boot.scr`, and in `rockchip/`
  the RG353V's device tree and its panel overlay,
  `rk3566-anbernic-rg353v-panels.dtbo`. Its `pie-installed.txt`
  lists the copied files that `blueberry-pie-os-update-boot` can record.
  update-boot can then remove a listed file once it leaves the boot
  directory.
- Partition 2 of `-hfs`: HFS+, case-sensitive and journaled, named
  "Blueberry Pie OS", of 3 GiB. It holds the root file system and does
  not grow.
- Partition 2 of `-zfs`: the ZFS pool `pie`, of 3 GiB. The ZFS image needs
  2 GB of memory or more.
- The last 1 MiB: no partition covers it. The `-zfs` image's first boot
  grows the pool up to the card's last MiB, and moves the GPT's backup
  there.
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
per line. Both images get the same packages:

- `rpi-firmware`, `openssh` and `sudo`.
- `zfs` and `pie-zfsroot`. On an HFS+ root, dpkg keeps its usual
  settings, and apt's hooks do nothing. The build fails if dpkg's
  settings change. `softreboot` restarts user space. The other ZFS tools
  say that the root is not a ZFS dataset.
- `u-boot-rk3566` and `rk3566-firmware`, for the RG353V. On a Raspberry
  Pi, `pie-update-loader` writes nothing.
- The WiFi. `piewifi` has `pie-wifi`, the 802.11 stack and the Raspberry
  Pi 4 and 500 driver, with `pie-firmware-brcm`. `piewifi-rtw88` has the
  RG353V's driver, with `pie-firmware-rtw88`.

The build fails if they install no loader, `boot.scr` or RG353V device
tree, or if `tools/checkloader.py` finds the loader's layout wrong. Each
package comes with the packages it depends on, at its newest version.
The `.manifest` next to each image lists them. The two are the same.

## Building

```
./build.sh [-r REPO_URL] [-k KEYRING] [-p PACKAGES] [-x DIR] [-o OUTDIR] VERSION
```

`-p` takes another list of packages in place of `packages`, for both
images. `-x` names a directory of .deb files, which take the place of the
repository's packages of the same names or add to them.

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

`tests/mkimage.sh` tests the disk layout that `tools/mkimage.sh` writes:
where the partitions start, the zeros before partition 1, the last 1 MiB,
and a loader written with `-l`, with both copies of its GPT. It also
checks the boot partition's `pie-installed.txt`, a boot directory with
the RG353V's files beside the Raspberry Pi's, and each loader that
`tools/checkloader.py` refuses.

The repository's InRelease must be signed by a key in
`keys/blueberry-pie-os-archive-keyring.gpg`.

## Releases

A tag builds the images, attests them and releases:

- `blueberry-pie-os-arm64-VERSION-hfs.img.xz` and its `.manifest`;
- `blueberry-pie-os-arm64-VERSION-zfs.img.xz` and its `.manifest`;
- `SHA256SUMS`.

Write an image to an SD card of 4 GB or more with any image writer. Each
image is 3,775,922,176 bytes.

On the RG353V, put the card with the `-zfs` image in TF1. The loader on
the eMMC finds U-Boot on the card through the GPT. An RG353V with no
loader on its eMMC reads the card's loader from sector 64. U-Boot runs
`boot.scr`, which starts pieboot with the line in `cmdline.txt`.

WiFi can be set up before the first boot. Put a `wifi.txt` on the
`PIEBOOT` partition with an `ssid=` line, and for a WPA2 network a
`passphrase=` line after it. At boot, rc stores the networks with
`pie-wifi import` and deletes the file. See pie-wifi(8).

## A fallback for panics and failed boots

`docs/trial-boot.md` explains how to set up a fallback on a Pi: a second
system boots, and if it fails to boot, hangs or panics, the Pi falls back
to the system that works. The scripts are in `tests/pi`.
