# Trial boots with a way back

This guide sets up a second system on a Raspberry Pi with a fallback to
the system that works. Once the way back is armed, a failure of the new
system brings the Pi back to the working one: a failed boot, a hang, a
panic, a lost network, or a plain reboot. The SD card stays in the Pi.
The scripts are in `tests/pi`.

Some moments are not covered, and need care:

- **The first boot of a new pieboot on a board.** pieboot arms the way
  back itself. If it hangs before it sets the tryboot flag, the Pi stays
  hung. Step 2 tries this first with A's own kernel, before B is
  involved.
- **A trial with `pieboot.fallback=flag`.** It sets the flag but arms no
  watchdog. A hang before the kernel arms its own watchdog stays hung.
- **A trial with `nodeadline`.** The kernel feeds the watchdog from the
  moment it takes it over. A system that hangs after that, before
  deadman runs, stays hung. `trial.sh` refuses this with
  `pieboot.fallback=1` unless `PI_ALLOW_NODEADLINE=1` is set.
- **A hang late in a shutdown.** Once a shutdown is under way, the
  watchdog driver ends all check-ins, so that a daemon the shutdown
  kills cannot cause a panic. It still feeds the hardware watchdog. A
  shutdown that hangs after that point, while the kernel still runs,
  stays hung. This applies to every reboot of B.
- **The switch of `config.txt`.** `trial.sh` writes the new
  `config.txt` beside the old one and renames it into place. A power cut
  in that moment can leave a boot partition the firmware cannot use.

If one of these goes wrong, the card has to come out. "Card out" below
says how to put it right. So before each of these moments, get an
explicit go from whoever is responsible for the Pi, and from someone
who can reach it if it does not come back. In the steps below, they are
marked **Needs a go**.

## The two systems

- **A** is the system on the card now. It is the way back, so nothing
  here changes it, apart from the directory `/pie-b` and the program
  `/usr/appleinternal/sbin/launchd.pieb`. Root logs in to A with an ssh
  key.
- **B** is the system under test. It lives in the directory `/pie-b` on
  A's volume. The card needs no new partition. The kernel refuses to
  write the partition table of a disk that is in use.

The boot partition gets these changes, and nothing else:

- `config.txt` gets a last `[all]` section that boots the files in
  `trial/`. This is the trial config.
- `tryboot.txt` is the old `config.txt`. It boots A.
- `trial/` holds B's pieboot, kernel bundle and `cmdline.txt`, and the
  device trees and overlays.
- `config-pie-orig.txt` is another copy of the old `config.txt`.

## How the Pi gets back to A

The firmware's tryboot flag does the work. A reset with the flag set
boots `tryboot.txt` instead of `config.txt`, once. Each layer of B's boot
makes sure that a failure ends in a reset while the flag is set.

1. The firmware boots `config.txt`, which runs `trial/pieboot.bin`.
2. pieboot reads `pieboot.fallback=1` in `trial/cmdline.txt`. It sets the
   tryboot flag through the firmware mailbox. Then it arms the PM
   watchdog with its full count, about 16 seconds. From here on, any
   reset boots A.
3. The kernel takes the watchdog over and keeps it fed. It reads
   `pie_watchdog_boot=N`. If no process checks in with the watchdog
   within N seconds, the kernel panics. A panic resets the board.
4. The kernel runs `/usr/appleinternal/sbin/launchd.pieb`, because the
   boot-args have `launchdsuffix=pieb`. This small program, built from
   `tests/pi/pieb-init.c`, mounts the root read-write and a devfs on
   `/pie-b/dev`. Then it changes its root to `/pie-b` and runs B's
   launchd. If a step fails, it reboots.
5. Once B is up, `deadman` takes over from the boot deadline. It checks
   in every 5 seconds, but only while a heartbeat file keeps changing.
   The controlling host touches that file over ssh. If the host loses B
   for 2 minutes, the check-ins stop, and the kernel panics a minute
   later.

| What fails | What happens |
|---|---|
| pieboot or the kernel hangs | the PM watchdog resets the board into A |
| the kernel panics | the board resets into A |
| launchd.pieb or B's launchd fails | launchd.pieb reboots into A, or the boot deadline does |
| B boots but sshd never comes up | the boot deadline panics, then A |
| ssh to B is lost later | deadman stops, the kernel panics, then A |
| B is rebooted on purpose | the flag is still set, so A, unless the shutdown hangs late |

A boot of A uses up the flag. While the trial config is in place, A's
next reboot tries B again. To stop trying B, take the trial config out.

## What you need

- pieboot 0.1.1 or later for `trial/pieboot.bin`. It has the fallback
  boot.
- For B, a kernel with `pie_watchdog_boot`. Without one, give
  `trial.sh` the `nodeadline` argument. Then nothing protects B's boot
  until deadman runs.
- Root ssh by key to A.
- Room on A's volume for B's archive, its unpacked tree and 1 GB more.
- A Linux host with Bash, Python 3, OpenSSH, xz, GNU tar and GNU
  coreutils 9.3 or later.
- pietoolchain, to build three small programs: `tests/pi/pieb-init.c`,
  `tests/pi/deadman.c` and `tests/list-accounts.c`. Use its clang and
  the flags in `/usr/share/pietoolchain/rules.mk`. deadman also needs
  `-framework CoreFoundation -framework IOKit`.
- If you can reach the card, a full image of it before step 3. The
  backup in step 1 covers the boot partition, `/etc` and the dpkg state,
  not A's whole volume. B runs as root on that volume.

## Making B

B is the root of a system image, as a tar file:

1. Build an image with `build.sh`.
2. Copy its partition 2 out of the image, and mount it read-only.
3. Make a tar of it with `tar --numeric-owner -cpf`.
4. Delete `./.journal` and `./.journal_info_block` from the tar.
5. Add ssh host keys made for B, as
   `./private/etc/ssh/ssh_host_*_key`, mode 600, and `.pub`, mode 644,
   all owned by root.
6. Compress the tar with xz. `pieb.sh` sends it in 4 MB pieces.

A and B answer on the same address with different host keys. Keep three
known_hosts files: `known_hosts` with A's keys, `known_hosts-b` with B's,
and `known_hosts-ab` with both. ssh accepts either key from
`known_hosts-ab`, so use it for a reboot from one system to the other.
`reboot.sh` then checks which system came up.

Make a directory `trial-b` with `pieboot.bin` and `xnu.bundle` from the
same image's partition 1, and a `cmdline.txt` as in step 4.

## Step by step

Each script takes `root@HOST KNOWN_HOSTS OUTPUT`, after an action word
for `trial.sh`, `pieb.sh` and `deadman.sh`. OUTPUT is a new directory on the controlling host for that step's records. The examples
are for a Pi 4, whose device tree is `bcm2711-rpi-4-b.dtb`. A Pi 5 uses
`bcm2712-rpi-5-b.dtb`, and a Pi 500 `bcm2712-rpi-500.dtb`. `trial.sh`
takes the device tree's name, not a path.

### 1. Look, then back up

```sh
tests/pi/inventory.sh root@PI known_hosts out/inventory
tests/pi/backup.sh root@PI known_hosts out/backup
```

`inventory.sh` changes nothing. `backup.sh` copies the boot partition's
files and their sums, the first 16 MiB of the disk, `/etc` and the
dpkg state. Keep the backup off the Pi. `trial.sh` checks the boot
partition against it before every change.

### 2. Prove the way back on each new board

Run these with A's own kernel before B is involved. Each run sets the
trial up, reboots and tears it down again. `trial.sh setup` refuses
unless the boot partition matches the backup.

1. **The flag alone.** **Needs a go:** the first boot of the new
   pieboot, and a switch of `config.txt`. Make `trial-a` from the backup: the new
   `pieboot.bin`, A's `xnu.bundle` from `out/backup/fat`, and A's
   `cmdline.txt` from there with `pieboot.fallback=flag pie.slot=trial`
   added to its line.

   ```sh
   tests/pi/trial.sh setup root@PI known_hosts out/t1 out/backup trial-a \
     bcm2711-rpi-4-b.dtb flag nodeadline
   tests/pi/reboot.sh root@PI known_hosts out/r1 trial
   tests/pi/reboot.sh root@PI known_hosts out/r2 good
   tests/pi/trial.sh teardown root@PI known_hosts out/t2 out/backup
   ```

   The first reboot must come back with `pie.slot=trial` in
   `kern.bootargs`. The second must come back without it, because the
   flag sent it to `tryboot.txt`. If the second comes back in the trial,
   the bootloader ignores tryboot: run the teardown and stop here.

   If a reboot fails while A answers, run the teardown before anything
   else. That holds for every step below.
2. **The flag and the watchdog.** **Needs a go:** a switch of
   `config.txt`, and a trial with `nodeadline`. In
   `trial-a/cmdline.txt`, change `pieboot.fallback=flag` to
   `pieboot.fallback=1`. A's kernel takes the watchdog over. The examples
   assume that A's kernel has no `pie_watchdog_boot`, so they use
   `nodeadline`. If it has one, add `pie_watchdog_boot=240` to the line
   instead, and leave out `nodeadline` and `PI_ALLOW_NODEADLINE`.

   ```sh
   PI_ALLOW_NODEADLINE=1 tests/pi/trial.sh setup root@PI known_hosts out/t3 \
     out/backup trial-a bcm2711-rpi-4-b.dtb nodeadline
   tests/pi/reboot.sh root@PI known_hosts out/r3 trial
   tests/pi/reboot.sh root@PI known_hosts out/r4 good
   tests/pi/trial.sh teardown root@PI known_hosts out/t4 out/backup
   ```
3. **A kernel that cannot start.** **Needs a go:** a switch of
   `config.txt`. Copy `trial-a` to `trial-bad`, and
   replace its `xnu.bundle` with a file of the same size full of zeros.

   ```sh
   PI_ALLOW_NODEADLINE=1 tests/pi/trial.sh setup root@PI known_hosts out/t5 \
     out/backup trial-bad bcm2711-rpi-4-b.dtb nodeadline
   tests/pi/reboot.sh root@PI known_hosts out/r5 good
   tests/pi/trial.sh teardown root@PI known_hosts out/t6 out/backup
   ```

   The reboot must come back in A. pieboot arms the watchdog before it
   reads the bundle, so the watchdog brings it there about 16 seconds
   later.

### 3. Install B

From A:

```sh
tests/pi/pieb.sh install root@PI known_hosts out/i b-root.tar.xz pieb-init
tests/pi/pieb.sh rootkey root@PI known_hosts out/k ~/.ssh/id_ed25519.pub
```

`rootkey` lets root log in to B by key while B is tested. B's
`sshd_config` says `PermitRootLogin no`, so `rootkey` puts
`PermitRootLogin prohibit-password` before it. It keeps the original
and its sum.

### 4. Boot B

`trial-b/cmdline.txt` is one line:

```
serial=3 debug=0x8 rd=uuid boot-uuid=A-VOLUME-UUID launchdsuffix=pieb pieboot.fallback=1 pie_watchdog_boot=240 pie.slot=trial
```

**Needs a go:** a switch of `config.txt`. The `boot-uuid` is A's
volume, as in A's own `cmdline.txt`, because B is a directory on it. B has 240 seconds from boot until deadman must
check in.

```sh
tests/pi/trial.sh setup root@PI known_hosts out/t7 out/backup trial-b \
  bcm2711-rpi-4-b.dtb
PI_REBOOT_WAIT=600 tests/pi/reboot.sh root@PI known_hosts-ab out/r6 pieb
```

The reboot from A goes to the trial config, which boots B. `pieb`
checks that the system that came up is B: `launchdsuffix=pieb` is in
the boot-args, `/etc/pie-b-id` exists, and `/pie-b` does not.
`PI_REBOOT_WAIT` must be longer than the boot deadline and a boot of A.
If B never comes up, the deadline sends the Pi to A, and `reboot.sh`
fails with A's boot-args.

If `trial.sh setup` fails, do not reboot. Run `trial.sh teardown`, and
go on only when it passes.

### 5. Start deadman in B, at once

```sh
tests/pi/deadman.sh start root@PI known_hosts-b out/d deadman
tests/pi/deadman.sh beat root@PI known_hosts-b out/hb &
```

Do this at once. The deadline counts from the start of B's kernel, and
`reboot.sh` says how many seconds the reboot took. Most of the 240
seconds can be gone by the time it returns. `start` passes once deadman checks in.
`beat` touches the heartbeat file every 30 seconds. Keep it running for
as long as B is up, and stop it with `kill %1` before you go back to A.

### 6. Test B

```sh
PI_FAT_SUMS=out/t7/fat-sums-expected.txt \
PI_BUNDLE=trial-b/xnu.bundle PI_KERNEL=KERNEL-VERSION \
LIST_ACCOUNTS=list-accounts \
tests/pi/pi-checks.sh root@PI known_hosts-b out/c-kernel kernel
```

Run one area at a time, each with a new OUTPUT, in this order: kernel,
storage, network, clock, logging, login, audit, passwords, users,
accounts, sysmon, cleanup. accounts expects the user ann that users
makes. cleanup takes ann away. Stop at the first area that fails. Each
area writes `results.txt` with a PASS or FAIL line per check. Before
each area, `pi-checks.sh` checks that the hardware watchdog is armed,
that deadman is checking in, that the heartbeat is less than 90 seconds
old, and that the check-ins keep renewing. cleanup only removes an ann
that the users area made.

storage runs `fsck_hfs -l`, which holds A's volume still while it reads
it. On a full volume that can take minutes. If the heartbeat cannot
touch its file for 2 minutes, deadman stops and the board resets into
A. That is safe, but the area then has to run again.

storage needs `PI_FAT_SUMS`, the sums `trial.sh setup` expected. kernel
needs `PI_BUNDLE`, the bundle in `trial-b`, and `PI_KERNEL`, the
version of the kernel package in B. accounts needs `LIST_ACCOUNTS`, the
build of `tests/list-accounts.c`. passwords puts pie's password back
when it ends, through root if it has to.

### 7. Go back to A

Reboot B. The flag is still set, so the Pi comes back in A:

```sh
kill %1
tests/pi/reboot.sh root@PI known_hosts-ab out/r7 good
```

A reboot from A goes to B again while the trial config is in place.

### 8. Finish

From A. **Needs a go:** a switch of `config.txt`.

```sh
tests/pi/trial.sh teardown root@PI known_hosts out/t8 out/backup
tests/pi/pieb.sh norootkey root@PI known_hosts out/n
tests/pi/pieb.sh remove root@PI known_hosts out/x
```

`teardown` must come first. `remove` refuses while the boot partition
still holds a trial, and while it runs in B. `trial.sh status` compares
the boot partition with the backup at any time.

## Keeping B as the working system

To keep working on B after the tests, keep the trial config and the way
back, and let the Pi look after itself without the controlling host's
heartbeat. The trial's `cmdline.txt` must have `launchdsuffix=pieb`,
`pieboot.fallback=1` and `pie_watchdog_boot`, as in step 4. Stop
`deadman.sh beat` and `deadman.sh stop` first, then from A:

```sh
tests/pi/pieb.sh keep root@PI known_hosts out/keep deadman
tests/pi/reboot.sh root@PI known_hosts-ab out/r8 pieb
```

`keep` changes nothing in the boot that is running. The reboot starts B
with all of it in place:

- **In B, a watcher.** A line at the end of B's `/etc/rc` starts
  `pie-b-watch`. It starts deadman at once, which ends the boot
  deadline. Every 30 seconds it touches deadman's heartbeat if sshd
  answers on B's address and the default gateway answers, by ping or
  ARP. If they do not, for 4 minutes, deadman stops checking in, and a
  minute later the board resets into A. Do not use `deadman.sh` while
  keep is in place: `start` refuses, as deadman runs already, and `stop`
  would end the watcher's deadman and leave B without protection.
- **In A, a return.** A line at the end of A's `/etc/rc` starts
  `pie-b-return`. 5 minutes after A boots, once nobody is logged in to
  A, no apt or dpkg runs and no `tests/pi` script holds the boot
  partition, it reboots into B. So a reboot or a crash of B comes back to
  B by itself, by way of A.
- **In B, boot files into `trial/`.** B's `update-boot` is diverted to
  `update-boot-trial`. A new kernel bundle goes into
  `trial/xnu.bundle`, and the one before stays as `xnu.bundle.old`. A bad
  bundle still falls back to A. A new `pieboot.bin`, device tree or
  overlay could stop the way back, so it goes in as `trial/FILE.pending`
  only. Check it, then move it into place by hand, from A, after a go.
  The boot partition's own files are A's, and it never writes them. A
  new firmware does not reach B, because the firmware always comes from
  the boot partition's root.

To stay in A, log in to A within the 5 minutes and create
`/var/db/pie-b-stay`. To go back to B later, delete it and reboot A. A
also stays after three returns in a row in which B never got healthy, so
a broken B does not cycle for ever. B reports its health in
`/pie-b/private/var/db/pie-b-healthy`, as A sees it, and A deletes that
file each time it counts it. To try B again after that, fix B, delete
`/var/db/pie-b-returns`, and reboot A. If A cannot record a return, it
stays in A.

To work on B, log in as pie with its password. Root logs in by key only
if `rootkey` is in place. The watcher checks sshd from inside B, so it
cannot see a fault that only a login from outside would show. If a
change in B locks everyone out of ssh while sshd still answers, B never
goes back to A, and the card has to come out. Test changes to sshd, PAM
and the accounts with a second session open.

Once B's boot files change, `trial.sh status` and `PI_FAT_SUMS` no longer
match the setup. That is expected.

To stop keeping B, from A, with `/var/db/pie-b-stay` in place:

```sh
tests/pi/pieb.sh unkeep root@PI known_hosts out/unkeep
```

`unkeep` stops a waiting return, takes the two lines out of the `/etc/rc`
files and puts B's `update-boot` back. If it stops halfway, run it again.
The logs `/var/log/pie-b-return.log` and B's `pie-b-watch.log` stay.
`trial.sh teardown` refuses while keep is in place without the stay
file. You are in A already, so finish with step 8.

## When something goes wrong

- **B does not come back, but A does:** A's `kern.previous_panic` and
  `/var/log/panic-*` hold the panic. B's own logs are in
  `/pie-b/private/var/log`.
- **Nothing answers when `reboot.sh` gives up:** the Pi may still be on
  its way back. A B without ssh only panics at its boot deadline, or 3
  minutes after the heartbeat stops. Wait that long, plus a boot of A,
  and try `ssh` with `known_hosts-ab`. If nothing answers then, the card
  has to come out. The backup has all of the boot partition.
- **`trial.sh` fails:** do not reboot. Run `trial.sh teardown`, and check
  that it passes. `config-pie-orig.txt` is the old `config.txt` if
  anything is left.

## Card out

Put the card in any computer. Its boot partition is FAT, so any system
can read it.

1. Copy `config-pie-orig.txt` over `config.txt`. If it is missing, use
   `tryboot.txt`, or `fat/config.txt` from the backup.
2. Delete `tryboot.txt`, `trial/`, `config-pie-orig.txt`,
   `config.txt.new` and `pie-stage/`, where present.
3. Compare the files with `fat-sums.txt` from the backup. Copy back any
   that differ from the backup's `fat/` directory.

The card then boots A. `/pie-b` and the shim are still on A's volume.
`pieb.sh remove` takes them away.

## Limits

- Under QEMU there is no tryboot and no watchdog. A reset boots the same
  kernel and arguments again. Use QEMU to test the scripts, not the way
  back. Set `PI_QEMU=1` for `pi-checks.sh` there, so that its check
  before each area does not ask for an armed watchdog. The kernel area's
  watchdog-enabled check still fails there.
- The Pi 4 has no serial console here. Everything goes over ssh.
- B shares A's volume and runs on it as root, with the raw disk in its
  `/dev`. A B that fills the disk fills A's. A B that damages the volume
  damages A. After each session with B, run `fsck_hfs -l -n` on A's
  volume from A. The backup cannot restore A's volume.
- `trial.sh` checks before it changes anything that the shim and B's tree
  are on the Pi, when the trial's cmdline names `launchdsuffix`. Without
  the shim, the kernel would start A's own launchd instead.
