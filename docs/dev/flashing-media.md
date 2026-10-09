# Flashing a wic image to removable media

How to write an `edge-image-*.wic.zst` to an SD card or USB stick, and the one
pitfall that bites a card reused from another board.

## Two ways to write

Identify the target with `lsblk` first — it is the whole disk (`/dev/sdX`),
never a partition, and never the host's own disks.

Fast path — sparse-aware, for a blank or same-board card:

```bash
sudo bmaptool copy \
  build/<board>/tmp/deploy/images/<machine>/edge-image-dev-<machine>.rootfs.wic.zst \
  /dev/sdX
```

Full write — for a card previously used on a different board:

```bash
zstdcat build/<board>/tmp/deploy/images/<machine>/edge-image-dev-<machine>.rootfs.wic.zst \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

## Why a reused card needs the full write

The U-Boot environment lives in a raw area of the medium at
`EDGE_UBOOT_ENV_OFFSET` (`0x1F0000`, set per board in
`conf/machine/include/edge-board-<machine>.inc`) — raw bytes before the first
partition, not a file on any filesystem. `bmaptool copy` writes only the blocks
the `.bmap` marks as data (the GPT and the used blocks inside partitions), so it
leaves that pre-partition area untouched. A card previously written for another
board keeps that board's saved env there, and U-Boot prefers a CRC-valid saved
env over its compiled-in default — so the freshly flashed board runs the other
board's boot script.

Symptom: the board loops in U-Boot before Linux, running a boot script written for
another board. For example, a Pi 5 card that last held an RZ/V2L image runs that
env's `ext4load mmc 0:1` against its FAT boot partition, prints
`Can't set block device` and `[RAUC] verified slot FIT load/boot failed`, and
resets.

A full `dd` write covers the whole image, including the zeroed pre-partition
gap, so it overwrites any stale env. U-Boot then finds no valid saved env and
uses the board's own compiled-in default, which seeds the right env on first
boot. Equivalently, zero the env region before a
`bmaptool` copy:

```bash
sudo dd if=/dev/zero of=/dev/sdX bs=1M count=8 conv=fsync
```

This is safe in this repo because the env is a raw region, not a labelled
filesystem. (A project that stores the env as a file on a vfat partition deletes
that file instead, and must not zero the partition — a different remedy for the
same cause.)

## Rule

Blank or same-board card: `bmaptool` (fast). Card repurposed from another
board: full `dd`, or zero the first 8 MiB first. Every board in this repo keeps
its U-Boot env at the same raw offset, so this applies to any board added later.
