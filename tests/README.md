# PIE boot tests

Run from a Linux host with Bash, Python 3, OpenSSH, gpgv, dpkg-deb,
xz-utils and mtools. The host needs no root access or mounts for QEMU.
The scripts fetch the archive URL set by ARCHIVE_URL. They keep the
signed Release, verified indexes, the kernel deb and its extracted files.
Use a new output directory for each run.

Run the QEMU test with a built image and its manifest:

```sh
IMAGE_SHA256=EXPECTED_SHA256 tests/qemu-boot.sh \
  out/blueberry-pie-os-rpi-VERSION.img.xz \
  out/blueberry-pie-os-rpi-VERSION.manifest \
  /path/to/qemu-system-aarch64 22222 evidence/qemu
```

Both entry points accept these environment settings:

- PIE_PASSWORD is the pie password for SSH and sudo. It defaults to blueberry.
- ARCHIVE_URL is the host archive URL. It defaults to https://blueberrypieos.com/apt/.
- GUEST_ARCHIVE_URL is the guest archive URL. It defaults to ARCHIVE_URL.
- ARCHIVE_KEYRING is the host keyring path. It defaults to keys/blueberry-pie-os-archive-keyring.gpg in this repository.

For a local test archive on the QEMU host:

```sh
ARCHIVE_URL=http://127.0.0.1:18085/ \
GUEST_ARCHIVE_URL=http://10.0.2.2:18085/ \
ARCHIVE_KEYRING=/path/to/test-keyring.gpg \
  tests/qemu-boot.sh image.img.xz image.manifest /path/to/qemu 22225 evidence/qemu
```

The apt check copies the selected key to a temporary guest directory.
It uses signed-by for that source. It removes the temporary files after
reading the guest key back for independent signature verification.

An uncompressed image works too. IMAGE_SHA256 is optional. When set, it
must match the input file before decompression. The test modifies only
its own SD copy. It reads the first FAT partition through mtools. It
extracts pieboot.bin, bcm2711-rpi-4-b.dtb, xnu.bundle and cmdline.txt.
It records their hashes and the exact QEMU command.

QEMU uses raspi4b, 2 GiB, cortex-a72, SD index 1 and bcm2838-genet user
networking. The SSH forward listens on localhost. The test adds -v,
ml-timeout-ticket-lock-scale=20 and ml-timeout-lock-scale=20 to the boot
arguments.
It authenticates as pie with the image password through SSH_ASKPASS.
Privileged checks use sudo as pie. The password goes to sudo on stdin
before any guest script. It is absent from command arguments and logs.
Each command requires authentication. The pie account must be in admin.
It records the new SSH host key in its output directory. It stops only
the QEMU process it started. It leaves the SD copy for diagnosis.

Both tests check these results:

- A console login prompt and password SSH as pie.
- uname -v and kern.uuid against a kernel member of the archive bundle.
- The installed bundle hash against the FAT bundle and the archive deb.
- The deb SHA256 and size against Packages from a signed Release.
- The full kextstat list, including piegpio.
- No panic(cpu in the console, dmesg or system.log.
- Empty dpkg --audit output.
- Every dpkg-query package name and version against the manifest.
- apt update against the guest archive URL with signature checking enabled.
- The guest archive key and an independent Release signature check.

The apt check uses a temporary guest lists and cache directory. It uses
a temporary source and the selected archive key. It does not install
or upgrade packages. Its output includes authentication debugging and source files.
The guest must provide readable logs and a sha256sum command. A denied
log read fails the check. A missing system.log fails the check.
Archive helpers are shared by both entry points. kernel.py extracts the
bundle members and reads their Mach-O UUID and embedded version.
The QEMU console must identify the selected member and matching version.
A panic report's UUID must match that member too. The runtime check
compares sysctl and uname output with that identity.

A failed check makes the script exit nonzero. results.txt names each
result. A blocked guest check gets a separate evidence file. The scripts
do not repair failures. Setup errors also exit nonzero with stderr.

The QEMU test then checks the accounts. They live in OpenDirectory, in
/var/db/dslocal. sshd accepts password logins as pie with the default
password, blueberry, from the first boot. That is the owner's decision
for the image. These QEMU-only settings apply:

- PIE_NEW_PASSWORD is the password the test gives pie. It defaults to
  blueberry-test, and must differ from PIE_PASSWORD.
- ANN_PASSWORD is the password of the user the test adds. It defaults to
  ann-test.
- LIST_ACCOUNTS names a darwin-arm64 build of tests/list-accounts.c.
  Build it with pietoolchain's clang and the flags in
  /usr/share/pietoolchain/rules.mk. Without it, accounts-unique is
  BLOCKED, and the run fails.

The account checks, in order:

- passwd as pie with a wrong old password prints an error.
- passwd as pie changes the password. It answers the old password, then
  the new one twice, on a terminal, through ssh -tt.
- With the new password, ssh, sudo, chkpasswd and the console login
  work. With the old one, each is refused. chkpasswd's refusal is its
  Sorry message, as it exits 0 either way. The console login goes
  through the serial console: the test writes to QEMU's input through
  a FIFO, console.in.
- Root adds the user ann with dscl, as dscl(1)'s example does: uid 502,
  group staff, a home in /Users/ann, and a member of admin. passwd as
  root sets the password. Then id ann shows uid 502 and admin, ann logs
  in over ssh, sudo -l works for ann, the record has a GeneratedUID,
  and ls -l names ann as the owner of a file chowned to 502.
- opendirectoryd runs. The dslocal directories are 0700 root, the
  records 0600 root, with no dot files left.
- dscl . -read /Users/pie shows RecordName, UniqueID 501,
  PrimaryGroupID 20, NFSHomeDirectory, UserShell, RealName,
  GeneratedUID, the ShadowHash AuthenticationAuthority and Password
  ********, and no ShadowHashData. As pie, reading ShadowHashData by
  name fails with "No such key". As root it works; the test records
  only its length.
- As pie, dscl . -create /Users/x, setting pie's UniqueID to 0 and
  deleting the admin group fail with error 4001, and setting root's
  password with error 5101. Nothing changes.
- id pie, groups pie and groups show admin, and the primary group
  staff comes first.
- ls -l names pie and root as owners.
- list-accounts lists each user and group name once, though root and
  the system groups are in /etc and in dslocal.

The guest then reboots. shutdown -r stops QEMU, as it runs with
-no-reboot, and the test starts it again on the same SD copy. Its
console goes to console-reboot.log. With the new password, the account
checks, the password checks and ann's checks run again, with
-after-reboot in their names. Failed password checks lock an account
for a while after five in a row, so each refused check is followed by
one that works.

The passwords go to the guest on standard input or through
SSH_ASKPASS, never in command arguments. The test's SD copy keeps the
new passwords' hashes.

Take a Pi lease before the hardware test. Keep it for the whole run.
The script checks PI_LEASE is set. It does not acquire or validate a lease.
Arrange a live serial capture in PI_CONSOLE_LOG. It must include the
initial boot and continue through the reboot. Use a capture from this
run. Provide the pinned host key for the pie login. Logs, read-only FAT
snapshots and shutdown use sudo with pie's password.
PIE_PASSWORD defaults to blueberry.

```sh
PI_LEASE=YOUR_LEASE \
PI_CONSOLE_LOG=/path/to/live-console.log \
  tests/pi-test.sh pie@pi-host /path/to/known_hosts \
  out/blueberry-pie-os-rpi-VERSION.manifest evidence/pi
```

SSH uses StrictHostKeyChecking=yes and the supplied
known_hosts file. The script records a snapshot before and after reboot.
Snapshots include kernel identity, memory, kexts, packages, chosen device
tree properties, devices and dmesg. It copies the FAT files read-only and
records all FAT hashes. It requires the SSH connection to drop and
return, and kern.boottime to change. It repeats the guest checks and
compares kernel identity, packages, kexts and FAT hashes across reboot.
It leaves the device booted. It changes no installed package.

Validate the scripts from the repository root:

```sh
bash -n tests/qemu-boot.sh tests/pi-test.sh tests/common.sh
shellcheck -x -P SCRIPTDIR tests/qemu-boot.sh tests/pi-test.sh tests/common.sh
```

tests/dialog.py answers prompts. It runs a command, such as ssh -tt,
or watches a console log and writes to its input. It waits for each
prompt before it answers, since a program that turns off echo flushes
what was typed before.

QEMU cannot cover bcm2712, the Pi firmware's own boot path, or real I2C
and SPI traffic. A hardware reboot covers the firmware boot path. These
scripts do not generate I2C or SPI traffic.
