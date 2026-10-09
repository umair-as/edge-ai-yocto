# Bootchain update

The RAUC A/B flow updates the rootfs slots and the kernel FIT. The firmware that
runs before the kernel — boot loaders, the secure monitor, the TEE, U-Boot — lives
in storage RAUC never writes, so a fix to it reaches a provisioned board only
through a bootchain updater. Every board stores that firmware differently, so each
board has its own backend
([ADR-0014](../../adr/0014-bootchain-update-mechanism.md)).

## Boards

| Board (`BOARD=`) | Updater | What it writes | Page |
|---|---|---|---|
| `rzv2l` | `rzv2l-bootloader-update` | BL2 + FIP (TF-A, OP-TEE, U-Boot) to QSPI, the eSD raw area or eMMC `boot0` | [rzv2l.md](rzv2l.md) |
| `raspberrypi5` | `edge-rpi-eeprom` | Broadcom bootloader in the SPI EEPROM, flashed by the firmware on reboot | [raspberrypi5.md](raspberrypi5.md) |
| `raspberrypi5` | `edge-rpi-bootfiles-update` | U-Boot, board DTB and `config.txt` on the FAT boot partition | [raspberrypi5.md](raspberrypi5.md) |

A board without a row has no backend; `BOOTLOADER_UPDATE=1` is a no-op there and
`make` prints a warning.

## Build

```bash
make dev BOOTLOADER_UPDATE=1 BOARD=<board>     # or: make prod ...
```

Off by default: the flag installs the board's updater and its staged artifacts into
the image. Built without it, no bootchain updater is present.

## What every backend guarantees

- **Attended and opt-in.** An operator runs the updater; no service, timer or RAUC
  hook starts it, and an ordinary reboot never begins an update.
- **Everything is checked before the first write.** Each staged artifact matches the
  SHA-256 in the image's manifest, and every board-specific guard (storage layout,
  board variant, medium) passes for every artifact before any byte is written. A
  target that already holds the artifact is skipped.
- **Backup first.** What a write replaces is saved under
  `/data/<backend>/backup/<run-id>/` with its location and hash. Each invocation
  gets its own run directory.
- **Readback.** After a write the target is read back from the medium, not from the
  page cache, and re-hashed; a mismatch stops the run.
- **Restore.** `--restore <run-id>` writes a run back through the same guards, only
  to the backend's fixed bootchain locations, and backs up what it replaces, so a
  restore is itself reversible.
- **`--dry-run`** prints the plan and writes nothing.

`edge-rpi-eeprom` is the exception to backup, readback and restore: it stages a
signed image and the Pi firmware performs and verifies the flash on the next
reboot; its recovery path is on [raspberrypi5.md](raspberrypi5.md).

The storage itself is single-copy: there is no A/B redundancy and no runtime
rollback. A power loss during a write is recovered with the board's out-of-band
procedure, on the board's page.

## Trust anchor coupling

U-Boot verifies the kernel FIT against the public key in its control DTB. A
bootchain whose DTB does not hold the key the installed slot FITs were signed with
rejects both slots and resets in a loop. Update or restore only to a bootchain built
with the current FIT signing key; the staged artifacts of an image build satisfy
this by construction.

## Testing

Each backend carries an on-target failure suite or test list on its page. A case
passes only when the updater refuses with the expected message and the bootchain
storage is byte-identical afterwards. `scripts/dev/fit-verifier-fixtures.sh` builds
host-side negative FIT fixtures from a signed `fitImage` and runs `fit_check_sign`
over them; `scripts/dev/serial-boot-capture.py` records a boot from the serial
console.

## Adding a board

Write a backend that meets the guarantees above, gate it on
`EDGE_ENABLE_BOOTLOADER_UPDATE` and the machine in the image recipes, add
`<board>.md` beside this page and a row to the table.

## Limitations

Delivery is not RAUC-integrated or unattended, and no backend enforces an
anti-rollback floor at boot (ADR-0014, Open questions).
