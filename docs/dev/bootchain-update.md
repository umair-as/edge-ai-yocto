# Bootchain update (RZ/V2L BL2/FIP)

**Scope: RZ/V2L only.** Bootchain update is a per-board capability
([ADR-0014](../adr/0014-bootchain-update-mechanism.md)): each board stores and
rewrites its pre-kernel firmware differently, so each needs its own backend. This
page is the RZ/V2L backend (BL2 + FIP); the Raspberry Pi 5 EEPROM backend is in
[`bootchain-update-rpi5.md`](bootchain-update-rpi5.md). `BOOTLOADER_UPDATE=1` is a
no-op on a board with no backend.

The RAUC A/B flow updates the rootfs and the kernel FIT, not the bootchain. BL2 and
the FIP (TF-A BL31, OP-TEE BL32, U-Boot BL33) live in single-copy storage outside the
RAUC slots — QSPI flash, the eSD raw boot region, or the eMMC boot partition — so
U-Boot/TF-A/OP-TEE fixes reach a provisioned board only through this updater. The
decision and its boundaries are [ADR-0014](../adr/0014-bootchain-update-mechanism.md);
eMMC placement is [ADR-0006](../adr/0006-emmc-gpt-boot-target.md).

The bootchain storage has no A/B redundancy and no runtime rollback. The updater
verifies and backs up before writing and reads back after, but a power loss mid-write
is recovered only with the Renesas SCIF Flash Writer over the serial console.

## Build

The tool is RZ/V2L-only and off by default. Build an image with it installed:

```bash
make dev BOOTLOADER_UPDATE=1        # or: make prod BOOTLOADER_UPDATE=1
```

This installs `/usr/sbin/rzv2l-bootloader-update`, the staged artifacts under
`/usr/share/rzv2l-boot/`, and `/usr/share/rzv2l-boot/manifest.tsv`.

For out-of-band provisioning (no image rebuild), build the host package:

```bash
make bootloader-package             # -> tmp/deploy/images/<machine>/rzv2l-bootloader-<machine>.tar.gz
```

The tarball holds the same BL2/FIP variants, the manifest, and the updater script.

## Boot source

The ROM loads BL2 from the medium selected by carrier switch SW11 (pins 1–3; pin 4 is
the 5 V input and stays ON): QSPI `OFF, OFF, OFF`, eSD `ON, ON, OFF`, eMMC
`ON, OFF, OFF`. SW1-2 on the SMARC module routes SDHI0 to the microSD (ON) or the eMMC
(OFF). QSPI is always probed and listed in `/proc/mtd`, whether or not it is the boot
source. Write to the medium the board actually boots from, and confirm it on the
console rather than assuming it:

- `NOTICE:  BL2: SYS_LSI_MODE:` reads `0x10203` for QSPI, `0x10200` for eSD and `0x10201` for eMMC.
- An edge-built bootchain prints `NOTICE:  [EDGE] BL2 …` and `[EDGE] UBOOT version=… profile=…`.
- U-Boot reads the same register and prints `[EDGE] UBOOT boot-source=qspi|esd|emmc`. It
  also passes the value to Linux as `/proc/device-tree/chosen/edge,boot-source`, which the
  login banner shows as `Boot source:`.
- The `U-Boot 2024.07 (…)` banner date is `SOURCE_DATE_EPOCH`, identical across builds of
  the same fork commit; it does not identify a build.

## Where each mode writes

Addresses are those TF-A reads (`plat/renesas/rz/common/plat_storage.c`,
`RZG2L_*_FIP_BASE`):

| mode | BL2 | FIP | status |
|---|---|---|---|
| `qspi` | `mtd0` (QSPI 0x0) | QSPI 0x20000 = `mtd1` + (0x20000 − `mtd1` start), derived from sysfs | write, boot and rollback hardware-validated 2026-10-07; FIP-only restore 2026-10-09 |
| `esd` | boot SD @ 0x200 | boot SD @ 0x20000 (WIC sector 256) | write and boot hardware-validated 2026-10-07 |
| `emmc` | `mmcblk0boot0` @ 0x200 (sector 1) | `mmcblk0boot0` @ 0x20000 (sector 256, [ADR-0006](../adr/0006-emmc-gpt-boot-target.md)) | write, restore and boot hardware-validated 2026-10-07 |

## On-target usage

Run as root with an explicit mode and variant; `--dry-run` prints the plan and writes
nothing. A QSPI write and its full-partition backup take under a minute; run long writes
as a transient unit so a dropped SSH session cannot interrupt them:

```bash
sudo rzv2l-bootloader-update --mode qspi --variant pmic --dry-run
sudo systemd-run --unit=bl-update --collect \
    /usr/sbin/rzv2l-bootloader-update --mode qspi --variant pmic --yes
journalctl -u bl-update -o cat
```

`--variant` must match the board: the SMARC EVK with the RAA215300 PMIC uses `pmic`.
The tool reads the PMIC from the device tree and refuses a mismatched variant.

A reboot activates the new bootchain. Check the console for `[EDGE] BL2` and
`[EDGE] UBOOT` and the expected `SYS_LSI_MODE`.

## What the updater guarantees

Every check below runs for every artifact before the first byte is written: root and
explicit mode/variant; variant equals the detected PMIC; artifact SHA-256 equals the
manifest; QSPI partition labels are `bl2`/`fip`; QSPI FIP offset is inside `mtd1` and
erase-aligned; each target holds offset + size. A target already holding the artifact
is skipped. Before a write, the current content is saved under
`/data/rzv2l-boot/backup/<run-id>/` as `<part>.img` plus `<part>.meta` (target, offset,
size, SHA-256); a QSPI partition is saved whole, because `flashcp` erases whole 4 KiB
blocks. After writing, the target is read back and re-hashed; a mismatch stops the run.
FIP is written before BL2.

## Rollback

`--restore <run-id>` writes a run's backup back through the same guards (labels,
capacity, skip-if-current, backup-first, readback) and itself backs up what it
replaces, so a restore can be undone with the run it creates. A run holds only the
parts its update wrote (a FIP-only update leaves no `bl2.img`); restore writes those
back and leaves the rest untouched. A part with an `.img` but no `.meta`, or the
reverse, is refused as a corrupt backup.

```bash
sudo ls /data/rzv2l-boot/backup/
sudo rzv2l-bootloader-update --restore <run-id> --dry-run
sudo rzv2l-bootloader-update --restore <run-id> --yes
```

A restored bootchain must still verify the installed kernel FIT. A U-Boot whose control
DTB does not hold the key the current FIT is signed with rejects it at every boot
(`edge-fit-dev- error!`) and the board resets in a loop, rewriting the U-Boot
environment on each attempt. Roll the bootchain back only to a build that trusts the
current FIT signing key.

## Recovery

When the bootchain on the selected medium no longer boots, switch SW11 to another
medium that holds a working bootchain (an SD written from the WIC carries one), boot
Linux, and `--restore` or re-run the update.

The eMMC cannot be reached from a Linux booted off the SD (SW1-2 routes SDHI0 to one or
the other). A broken eMMC `boot0` is restored from the U-Boot console of a working
bootchain (QSPI, or eMMC itself while its U-Boot still runs), from a full `boot0` image
kept on the eMMC's `/data` partition:

```
=> ext4load mmc 0:4 0x58000000 /rzv2l-boot/boot0-full.bin
=> hash sha256 0x58000000 ${filesize}          # compare with the saved hash
=> mmc dev 0 1                                  # hardware partition boot0
=> mmc write 0x58000000 0 0xFC00                # 0xFC00 blocks = the 31.5 MiB boot0
=> mmc read 0x60000000 0 0xFC00
=> hash sha256 0x60000000 0x1F80000             # must equal the image hash
=> mmc dev 0 0
=> reset
``` Without such a medium, re-flash BL2 and
FIP with the Renesas SCIF Flash Writer
(`Flash_Writer_SCIF_RZV2L_SMARC_PMIC_DDR4_2GB_1PCS.mot` for the PMIC board) in SCIF
download mode (SW11 `OFF, ON, OFF`).

## Testing

`scripts/dev/rzv2l-bootloader-failure-suite.sh` runs on the board and feeds the
updater every condition it must refuse: corrupt artifact, wrong manifest hash, wrong
mtd label, wrong variant, oversized image, bad QSPI FIP address, not root, operator
"no", missing, corrupt or half-present restore run. A case passes only when the updater refuses
with the expected message and the bootchain storage hashes are unchanged:

```bash
ssh devel@<board> 'bash -s -- --restore-run <run-id>' \
    < scripts/dev/rzv2l-bootloader-failure-suite.sh
```

`scripts/dev/fit-verifier-fixtures.sh` builds host-side negative FIT fixtures from a
signed `fitImage` (a flipped kernel byte, a flipped config byte, and a re-signed
FIT whose config references an image outside `sign-images`) and, with `--check`,
runs `fit_check_sign` over them. `scripts/dev/serial-boot-capture.py` records a boot
from the serial console and can stop U-Boot autoboot to run console commands.

## Scope

This path is attended and operator-run, and is deliberately independent of RAUC.
Delivery is not unattended or RAUC-integrated, and the bootchain has no
boot-enforced anti-rollback floor (ADR-0014, Open questions).
