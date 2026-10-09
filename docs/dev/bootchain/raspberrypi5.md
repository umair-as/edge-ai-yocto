# Bootchain update — Raspberry Pi 5

The Pi 5 bootchain has two parts, each with its own operator-run updater: the
**Broadcom bootloader in the SPI EEPROM** (`edge-rpi-eeprom`) and the **U-Boot, DTB
and `config.txt` files on the shared FAT boot partition**
(`edge-rpi-bootfiles-update`). The shared contract, build flag and limitations are
in [README.md](README.md).

## Build

`make dev BOARD=raspberrypi5 BOOTLOADER_UPDATE=1` adds `rpi-eeprom` (the updater
plus the `bootloader-2712/default` payload), `/usr/sbin/edge-rpi-eeprom`, and
`/usr/sbin/edge-rpi-bootfiles-update` with its staged U-Boot/DTB/`config.txt` and
manifest under `/usr/share/rpi-boot`. The RPi userland tools (`raspi-utils`) and
`/dev/vcio` are present without the flag.

## Dependencies this board needs

`rpi-eeprom-update` identifies the board from
`/sys/firmware/devicetree/base/system/linux,revision` and reads the running
bootloader version and config through `vcgencmd`. A stock mainline image has
neither:

- **`vcgencmd`** comes from `raspi-utils` and talks to the firmware mailbox through
  `/dev/vcio`, which the kernel's VCIO backport provides (`EDGE_ENABLE_VCIO`). On
  dev images the node is group `video`, so `devel` runs `vcgencmd` without root; on
  prod images it is root-only, because the mailbox passes any firmware property tag
  through, OTP writes included.
- **`/system/linux,revision`** is injected by the firmware into the DTB it hands
  U-Boot, but the kernel boots the signed FIT's own fdt, which has no `/system`
  node. The U-Boot patch `0001-rpi-forward-system-revision-to-kernel-fdt` forwards
  `/system` from U-Boot's control FDT onto the kernel fdt in `update_fdt_from_fw()`.
  Without it, `rpi-eeprom-update` reports "Device does not have a Raspberry Pi
  bootloader EEPROM" and refuses to run.

## SPI EEPROM (`edge-rpi-eeprom`)

A wrapper over `rpi-eeprom-update`. It stages a bootloader image to `/boot`; the
firmware flashes the EEPROM on the next reboot. The release channel is pinned to the
stable `default` set in the `rpi-eeprom` bbappend.

```bash
edge-rpi-eeprom status      # current vs available EEPROM version (no root needed)
sudo edge-rpi-eeprom stage  # stage the update to /boot (applies on next reboot)
sudo edge-rpi-eeprom cancel # remove a staged update
sudo reboot                 # apply a staged update
```

`status` exits 0 when up to date, 1 when an update is available. `stage` refuses
unless `/boot` is a mounted, writable FAT volume.

`stage` writes `recovery.bin`, `pieeprom.upd` and `pieeprom.sig` to `/boot` and
migrates the current bootloader config, so `BOOT_ORDER` and the rest survive. On
reboot the ROM runs `recovery.bin`, flashes `pieeprom.upd` after verifying it against
`pieeprom.sig`, renames `recovery.bin` to `RECOVERY.000` so it does not re-run, and
boots on. `edge-rpi-eeprom status` then reports "up to date" and
`vcgencmd bootloader_version` shows the new timestamp. `pieeprom.upd`/`pieeprom.sig`
may remain on `/boot`; they are inert once `recovery.bin` has become `RECOVERY.000`.
A `flashrom not found` note during `stage` is expected: the update uses the
interruption-tolerant reboot-time flash, not the live `flashrom` path.

Hardware-validated 2026-10-08: EEPROM moved to the May-2026 release, `RECOVERY.000`
present, board booted on the new firmware with `/system/linux,revision` intact.

### Recovery

The pinned `rpi-eeprom` has no A/B or tryboot rollback, so a bad or
power-interrupted flash needs a physical recovery SD. Prepare one before flashing a
board that cannot easily be re-imaged:

- Format a spare SD as FAT and copy `recovery.bin` and a known-good
  `pieeprom-<date>.bin` (renamed `pieeprom.upd`) plus its `pieeprom.sig` from
  `/usr/lib/firmware/raspberrypi/bootloader-2712/default/`, or use the Raspberry Pi
  Imager "bootloader recovery" image.
- Boot the Pi from that SD; the firmware reflashes a known-good EEPROM. Remove the SD
  and boot normally.

## FAT boot files (`edge-rpi-bootfiles-update`)

Rewrites `kernel_2712.img` (U-Boot), `bcm2712-rpi-5-b.dtb` and `config.txt` on the
shared FAT `/boot`. These files are single-copy: RAUC's rootfs A/B does not cover
them.

```bash
edge-rpi-bootfiles-update --dry-run                  # show what would change
sudo edge-rpi-bootfiles-update                       # back up, write, verify (prompts; --yes to skip)
sudo reboot                                          # the new files take effect on reboot
sudo edge-rpi-bootfiles-update --restore <run-id>    # roll back a run (ls /data/rpi-boot/backup)
```

In addition to the shared contract, `/boot` must be a mounted, writable FAT volume
with room for each file. Each file is backed up to `/data/rpi-boot/backup/<run-id>/`,
copied to a temporary name, verified from the medium, then renamed over the old one
and verified again; a failed copy leaves the current file in place. A restore that
removes a file absent from the backup backs that file up first.

`bcm2712-rpi-5-b.dtb` carries the injected FIT signing key (see "Trust anchor
coupling" in [README.md](README.md)). An unbootable `/boot` is recovered by
rewriting the card from a host ([flashing-media.md](../flashing-media.md)).

Hardware-validated 2026-10-08 (delivered by RAUC OTA, apply/backup/`--restore`
round trip hash-verified) and 2026-10-09 against a scratch FAT volume.

## Testing

- `edge-rpi-eeprom status` reports current, available and release accurately; a
  capability-off image has no `edge-rpi-eeprom`.
- `stage` refuses a read-only or non-FAT `/boot`; `cancel` removes the staged files.
- A real `stage → reboot → verify`: the EEPROM version moves, `RECOVERY.000`
  appears, the board boots with zero failed units, and `/system/linux,revision` is
  still present.
- `edge-rpi-bootfiles-update` apply, restore and a restore that removes a file, run
  with `BOOT_MP`/`BACKUP_DIR` pointed at a loop-mounted FAT so the real `/boot` is
  untouched.
