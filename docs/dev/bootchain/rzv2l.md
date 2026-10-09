# Bootchain update — RZ/V2L

`rzv2l-bootloader-update` rewrites BL2 and the FIP (TF-A BL31, OP-TEE BL32, U-Boot
BL33) on the RZ/V2L SMARC EVK. The shared contract, build flag and limitations are
in [README.md](README.md); eMMC placement is
[ADR-0006](../../adr/0006-emmc-gpt-boot-target.md).

## Build

`make dev BOOTLOADER_UPDATE=1` installs `/usr/sbin/rzv2l-bootloader-update`, the
staged BL2/FIP variants under `/usr/share/rzv2l-boot/` and their
`manifest.tsv`. For out-of-band provisioning without an image rebuild:

```bash
make bootloader-package    # -> tmp/deploy/images/<machine>/rzv2l-bootloader-<machine>.tar.gz
```

The tarball holds the same artifacts, the manifest and the updater script.

## Boot source and switches

Two switch banks decide what boots and what Linux sees:

| Switch | Where | QSPI boot | SD / eSD boot | eMMC boot | SCIF download |
|---|---|---|---|---|---|
| SW11 pins 1–4 (boot mode) | carrier | OFF, OFF, OFF, ON | ON, ON, OFF, ON | ON, OFF, OFF, ON | OFF, ON, OFF, ON |
| SW1-2 (SDHI0 media) | module | either | ON (microSD) | OFF (eMMC) | OFF to program the eMMC |

SW11 pin 4 is the 5 V input and stays ON. SW1-2 connects SDHI0 to the module microSD
or the module eMMC, never both: Linux sees the connected one as `/dev/mmcblk0`, and
only an eMMC has `mmcblk0boot0`. QSPI is always probed and listed in `/proc/mtd`,
whether or not it is the boot source.

Write to the medium the board boots from, and confirm it on the console:

- `NOTICE:  BL2: SYS_LSI_MODE:` reads `0x10203` for QSPI, `0x10200` for eSD and
  `0x10201` for eMMC.
- An edge-built bootchain prints `NOTICE:  [EDGE] BL2 …` and
  `[EDGE] UBOOT version=… profile=…`.
- U-Boot prints `[EDGE] UBOOT boot-source=qspi|esd|emmc` and passes the value to
  Linux as `/proc/device-tree/chosen/edge,boot-source`, which the login banner shows
  as `Boot source:`.
- The `U-Boot 2024.07 (…)` banner date is `SOURCE_DATE_EPOCH`, identical across
  builds of the same fork commit; it does not identify a build.

## Where each mode writes

Addresses are those TF-A reads (`plat/renesas/rz/common/plat_storage.c`,
`RZG2L_*_FIP_BASE`):

| mode | BL2 | FIP | status |
|---|---|---|---|
| `qspi` | `mtd0` (QSPI 0x0) | QSPI 0x20000 = `mtd1` + (0x20000 − `mtd1` start), derived from sysfs | write, boot and rollback hardware-validated 2026-10-07; FIP-only restore 2026-10-09 |
| `esd` | boot SD @ 0x200 | boot SD @ 0x20000 (WIC sector 256) | write and boot hardware-validated 2026-10-07 |
| `emmc` | `mmcblk0boot0` @ 0x200 (sector 1) | `mmcblk0boot0` @ 0x20000 (sector 256) | write, restore and boot hardware-validated 2026-10-07 |

## On-target usage

Run as root with an explicit mode and variant. A QSPI write and its full-partition
backup take under a minute; run long writes as a transient unit so a dropped SSH
session cannot interrupt them:

```bash
sudo rzv2l-bootloader-update --mode qspi --variant pmic --dry-run
sudo systemd-run --unit=bl-update --collect \
    /usr/sbin/rzv2l-bootloader-update --mode qspi --variant pmic --yes
journalctl -u bl-update -o cat
```

`--variant` must match the board: the SMARC EVK with the RAA215300 PMIC uses `pmic`.
A reboot activates the new bootchain; check the console for `[EDGE] BL2`,
`[EDGE] UBOOT` and the expected `SYS_LSI_MODE`.

## Guards

In addition to the shared contract, before the first write:

- the variant equals the PMIC detected from the device tree;
- the QSPI partition labels are exactly `bl2` and `fip`, BL2 sits at QSPI 0, and the
  FIP offset is inside `mtd1` and erase-aligned;
- the device on SDHI0 matches the mode: an SD card (no `boot0`) for `esd`, an eMMC
  for `emmc`. `--mode esd` on an eMMC would otherwise overwrite its GPT header at
  0x200;
- each target holds offset + size.

Backups go to `/data/rzv2l-boot/backup/<run-id>/` as `<part>.img` plus `<part>.meta`
(target, offset, size, SHA-256). A QSPI partition is saved whole, because `flashcp`
erases whole 4 KiB blocks. FIP is written before BL2. eMMC `boot0` is made writable
only for the writes and returned to read-only on every exit path.

## Rollback

```bash
sudo ls /data/rzv2l-boot/backup/
sudo rzv2l-bootloader-update --restore <run-id> --dry-run
sudo rzv2l-bootloader-update --restore <run-id> --yes
```

A run holds only the parts its update wrote (a FIP-only update leaves no
`bl2.img`); restore writes those back and leaves the rest untouched. A part with an
`.img` but no `.meta`, or the reverse, is refused as a corrupt backup, and a `.meta`
naming any location other than the six bootchain locations above is refused.

## Recovery

When the bootchain on the selected medium no longer boots, set SW11 to another medium
that holds a working bootchain (an SD written from the WIC carries one), boot Linux,
and `--restore` or re-run the update.

A Linux booted off the SD cannot reach the eMMC (SW1-2). A broken eMMC `boot0` is
restored from the U-Boot console of a working bootchain (QSPI, or the eMMC while its
U-Boot still runs), from a full `boot0` image kept on the eMMC's `/data` partition:

```
=> ext4load mmc 0:4 0x58000000 /rzv2l-boot/boot0-full.bin
=> hash sha256 0x58000000 ${filesize}          # compare with the saved hash
=> mmc dev 0 1                                  # hardware partition boot0
=> mmc write 0x58000000 0 0xFC00                # 0xFC00 blocks = the 31.5 MiB boot0
=> mmc read 0x60000000 0 0xFC00
=> hash sha256 0x60000000 0x1F80000             # must equal the image hash
=> mmc dev 0 0
=> reset
```

Without such a medium, re-flash BL2 and FIP with the Renesas SCIF Flash Writer
(`Flash_Writer_SCIF_RZV2L_SMARC_PMIC_DDR4_2GB_1PCS.mot` for the PMIC board) in SCIF
download mode.

## Testing

`scripts/dev/rzv2l-bootloader-failure-suite.sh` runs on the board and feeds the
updater every condition it must refuse: corrupt artifact, wrong manifest hash, wrong
mtd label, wrong variant, oversized image, bad QSPI FIP address, wrong SD/eMMC
medium, not root, operator "no", missing, corrupt, half-present or redirected restore
run:

```bash
ssh devel@<board> 'bash -s -- --restore-run <run-id>' \
    < scripts/dev/rzv2l-bootloader-failure-suite.sh
```
