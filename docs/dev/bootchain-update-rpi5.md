# Bootchain update (Raspberry Pi 5)

**Scope: Raspberry Pi 5 only.** Bootchain update is a per-board capability
([ADR-0014](../adr/0014-bootchain-update-mechanism.md)): each board stores and
rewrites its pre-kernel firmware differently. The RZ/V2L backend (BL2 + FIP) is in
[`bootchain-update.md`](bootchain-update.md); this page is the Pi 5 backend. It has
two operator-run parts: the **Broadcom bootloader in the SPI EEPROM**
(`edge-rpi-eeprom`) and the **U-Boot / DTB / `config.txt` files on the shared FAT
boot partition** (`edge-rpi-bootfiles-update`). Both are attended and never wired
into RAUC.

## What it is

`edge-rpi-eeprom` is an operator-run wrapper over `rpi-eeprom-update`. It stages a
bootloader EEPROM image to `/boot`; the firmware self-flashes the EEPROM on the next
reboot. It is gated by `BOOTLOADER_UPDATE=1` (sets `EDGE_ENABLE_BOOTLOADER_UPDATE`),
machine-gated to raspberrypi5, and installed with `rpi-eeprom` and `raspi-utils`.
There is no service: nothing updates automatically, and an ordinary reboot never
initiates an update.

The EEPROM release channel is pinned to the stable `default` set (not `latest`) in
the `rpi-eeprom` bbappend.

## Dependencies this board needs

`rpi-eeprom-update` identifies the board from `/sys/firmware/devicetree/base/system/linux,revision`
and reads the running bootloader version/config through `vcgencmd`. On this board
both need enabling that a stock mainline image lacks:

- **`vcgencmd`** comes from `raspi-utils` and talks to the firmware mailbox through
  `/dev/vcio`, which the kernel's VCIO backport provides (`EDGE_ENABLE_VCIO`). The
  `/dev/vcio` node is group `video`, so `devel` runs `vcgencmd` without root.
- **`/system/linux,revision`** is injected by the firmware into the DTB it hands
  U-Boot, but the kernel boots the signed FIT's own fdt, which has no `/system`
  node. The U-Boot patch `0001-rpi-forward-system-revision-to-kernel-fdt` forwards
  `/system` from U-Boot's control FDT onto the kernel fdt in `update_fdt_from_fw()`,
  so the revision reaches userspace. Without it, `rpi-eeprom-update` reports
  "Device does not have a Raspberry Pi bootloader EEPROM" and refuses to run.

## Build

```bash
make dev BOARD=raspberrypi5 BOOTLOADER_UPDATE=1     # or: make prod ...
```

The image then carries `rpi-eeprom` (the updater plus the `bootloader-2712/default`
payload), `raspi-utils`, `/usr/sbin/edge-rpi-eeprom`, and
`/usr/sbin/edge-rpi-bootfiles-update` (with its staged U-Boot/DTB/config.txt payload
and manifest under `/usr/share/rpi-boot`). Built without the flag, none of the
updaters is present (the RPi userland tools and `/dev/vcio` are always on).

## On-target usage

```bash
edge-rpi-eeprom status      # current vs available EEPROM version (no root needed)
sudo edge-rpi-eeprom stage  # stage the update to /boot (applies on next reboot)
sudo edge-rpi-eeprom cancel # remove a staged update
```

`status` exits 0 when up to date, 1 when an update is available. `stage` refuses
unless `/boot` is a mounted, writable FAT volume, so it never arms a partial update
on the wrong target.

Apply a staged update by rebooting:

```bash
sudo edge-rpi-eeprom stage
sudo reboot
```

`stage` writes `recovery.bin`, `pieeprom.upd` and `pieeprom.sig` to `/boot` and
preserves (migrates) the current bootloader config, so `BOOT_ORDER` and the rest
survive the update. On reboot the firmware ROM runs `recovery.bin`, flashes
`pieeprom.upd` after verifying it against `pieeprom.sig`, renames `recovery.bin` to
`RECOVERY.000` so it does not re-run, and boots on. Afterwards `edge-rpi-eeprom
status` reports "up to date" and `vcgencmd bootloader_version` shows the new
timestamp. (`pieeprom.upd`/`pieeprom.sig` may remain on `/boot`; they are inert once
`recovery.bin` has become `RECOVERY.000`.)

The update uses the staged-`recovery.bin` path, not the live `flashrom` path: a
`flashrom not found` note during `stage` is expected and means the interruption-
tolerant reboot-time flash is used.

## Recovery

The pinned `rpi-eeprom` has no A/B/tryboot rollback, so a bad or power-interrupted
flash needs a physical recovery SD. Prepare one before flashing a board you cannot
easily re-image:

- Format a spare SD as FAT and copy `recovery.bin` and a known-good
  `pieeprom-<date>.bin` (renamed `pieeprom.upd`) plus its `pieeprom.sig` from
  `/usr/lib/firmware/raspberrypi/bootloader-2712/default/` onto it, or use the
  Raspberry Pi Imager "bootloader recovery" image.
- Boot the Pi from that SD; the firmware reflashes a known-good EEPROM, then remove
  the SD and boot normally.

## Testing

Validate the full path on hardware, not just a build:

- `edge-rpi-eeprom status` reports current, available and release accurately; a
  capability-off image has no `edge-rpi-eeprom`.
- `stage` refuses a read-only or non-FAT `/boot`; `cancel` removes the staged files.
- A real `stage → reboot → verify`: the EEPROM version moves, `RECOVERY.000` appears,
  the board boots with zero failed units, and `/system/linux,revision` is still
  present (U-Boot forwarding still works on the new firmware).

## FAT boot files (U-Boot, DTB, config.txt)

`edge-rpi-bootfiles-update` rewrites the files the firmware and U-Boot read from the
shared FAT `/boot`: `kernel_2712.img` (U-Boot), `bcm2712-rpi-5-b.dtb` and `config.txt`.
It is the FAT-file sibling of the RZ/V2L `rzv2l-bootloader-update`: the same guard
chain (root; mounted writable FAT `/boot`; artifact SHA-256 ==
`/usr/share/rpi-boot/manifest.tsv`; skip-if-current; free-space), each file backed up
first and written as an atomic rename verified by read-back.

```bash
edge-rpi-bootfiles-update --dry-run                  # show what would change
sudo edge-rpi-bootfiles-update                       # back up, write, verify (prompts; --yes to skip)
sudo reboot                                          # the new files take effect on reboot
sudo edge-rpi-bootfiles-update --restore <run-id>    # roll back a run (ls /data/rpi-boot/backup)
```

These three files are **single-copy on the shared FAT partition** — RAUC's rootfs A/B
does not cover them, so there is no slot-switch rollback. The guard backs up the
current files to `/data/rpi-boot/backup/<run-id>/` first, and `--restore <run-id>`
writes them back through the same guards. A completely unbootable `/boot` is recovered
by rewriting it from a host (see [`flashing-media.md`](flashing-media.md)).

**The board DTB is the FIT trust anchor.** `bcm2712-rpi-5-b.dtb` carries the injected
FIT signing key; only apply boot files built with the key the installed slot FITs were
signed with, or U-Boot cannot verify either slot after the swap. The shipped DTB is the
pubkey-injected one the kernel recipe deploys, so a build with the current key is
correct by construction.

## Scope

Both paths are attended and operator-run. Bootchain delivery is not RAUC-integrated
or unattended, and no boot-enforced anti-rollback floor exists (ADR-0014, Open
questions).
