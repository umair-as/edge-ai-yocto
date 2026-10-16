# Bootchain update — RZ/V2L

The RZ/V2L bootchain is BL2 plus the FIP (TF-A BL31, OP-TEE BL32, U-Boot BL33). Two
tools rewrite it:

| Boot target | Tool | Writes |
|---|---|---|
| eMMC (`EDGE_BOOT_TARGET=emmc`) | RAUC bootloader slot, bundle `rzv2l-bootchain-bundle` ([ADR-0015](../../adr/0015-rzv2l-emmc-bootchain-rauc-boot-emmc.md)) | the inactive eMMC boot partition, then switches to it |
| QSPI, eSD; eMMC `boot0` provisioning | `rzv2l-bootloader-update` ([ADR-0014](../../adr/0014-bootchain-update-mechanism.md)) | the medium in place, header last |

The shared contract is in [README.md](README.md); eMMC placement is
[ADR-0006](../../adr/0006-emmc-gpt-boot-target.md).

## Boot source and switches

Two switch banks decide what boots and what Linux sees:

| Switch | Where | QSPI boot | SD / eSD boot | eMMC boot | SCIF download |
|---|---|---|---|---|---|
| SW11 pins 1–4 (boot mode) | carrier | OFF, OFF, OFF, ON | ON, ON, OFF, ON | ON, OFF, OFF, ON | OFF, ON, OFF, ON |
| SW1-2 (SDHI0 media) | module | either | ON (microSD) | OFF (eMMC) | OFF to program the eMMC |

SW11 pin 4 is the 5 V input and stays ON. SW1 is the two-lever DIP switch on the top of
the SMARC module, beside its microSD slot; SW1-1 stays ON (normal operation, OFF is
JTAG debug mode). SW1-2 connects SDHI0 to the module microSD or the module eMMC, never
both: Linux and U-Boot see the connected one as `mmc 0` / `/dev/mmcblk0`, and only an
eMMC has `mmcblk0boot0`. QSPI is always probed and listed in `/proc/mtd`, whether or
not it is the boot source.

Confirm the boot medium on the console:

- `NOTICE:  BL2: SYS_LSI_MODE:` reads `0x10203` for QSPI, `0x10200` for eSD and
  `0x10201` for eMMC (the same register is at `0x11020A00`, readable with `devmem2`).
- An edge-built bootchain prints `NOTICE:  [EDGE] BL2 …` and
  `[EDGE] UBOOT version=… profile=…`.
- U-Boot prints `[EDGE] UBOOT boot-source=qspi|esd|emmc` and passes the value to
  Linux as `/proc/device-tree/chosen/edge,boot-source`, which the login banner shows
  as `Boot source:`. A bootchain built before that U-Boot change sets no property.
- The `U-Boot 2024.07 (…)` banner date is `SOURCE_DATE_EPOCH`, identical across
  builds of the same fork commit; it does not identify a build.

## eMMC: RAUC bootloader slot

### Build

```bash
make dev EDGE_BOOT_TARGET=emmc             # image: patched RAUC, guards, bootloader slot
make bootchain-bundle EDGE_BOOT_TARGET=emmc
```

The image's `/etc/rauc/system.conf` gains

```
[handlers]
pre-install=/usr/lib/rzv2l-bootchain/preinstall

[slot.bootloader.0]
device=/dev/mmcblk0
type=boot-emmc
```

and the image carries `rzv2l-bootchain-guard` and RAUC 1.15.2 with the upstream
boot-emmc hook fix backported (`rpm -q rauc` → `rauc-1.15.2-r0.edge1`). The bundle
(`tmp/deploy/images/smarc-rzv2l/rzv2l-bootchain-bundle.raucb`) holds one image for the
boot partition: zero up to 0x1FF, `bl2_bp_mmc` at 0x200, the FIP at 0x20000. The build
refuses a BL2 whose header size word does not match its body, a FIP without a ToC, a
TF-A pin missing from the layout table (`EDGE_RZV2L_TFA_FIP_LAYOUT`), and a FIP whose
U-Boot DTB fails the FIT trust gate.

The bundle only replaces the bootchain: the board must already run an image built as
above. A board whose `boot0` holds a bootchain that sets no `edge,boot-source` is first
provisioned with `rzv2l-bootloader-update --mode emmc` (below).

### Install

```bash
sudo rzv2l-bootchain-authorize /data/rzv2l-boot/bundles/rzv2l-bootchain-bundle.raucb
sudo rauc install --require-manifest-hash=<hash printed above> \
    /data/rzv2l-boot/bundles/rzv2l-bootchain-bundle.raucb
sudo mmc extcsd read /dev/mmcblk0 | grep PARTITION_CONFIG   # 0x08 = boot0, 0x10 = boot1
sudo reboot
```

Keep bundles on `/data`; `/tmp` does not survive a reboot. `rzv2l-bootchain-authorize`
checks the bundle with the system keyring and records one authorization in `/run`:
this bundle's image digest and build id, this boot, 10 minutes by default
(`--ttl`, at most 3600 s). The next bootloader install attempt consumes it whether it
succeeds or not. `--status` shows it, `--revoke` drops it. Without an authorization
the install is refused before anything is written; rootfs bundles pass through the
same handler untouched.

`rauc install` then runs:

1. the pre-install handler: authorization, no other image in the bundle, the hook
   declarations and the reference hook stub, then the guards below;
2. RAUC clears and writes the inactive boot partition, between the slot pre-install
   hook (which checks the handler's approval) and the slot post-install hook (which
   reads the partition back and compares it with the image digest);
3. RAUC switches EXT_CSD[179] to that partition and re-reads it.

The journal (`journalctl -u rauc`) shows each step, from
`board: booted from emmc, boot0 active, writing boot1` to
`Boot partition /dev/mmcblk0boot1 is now active`.

Each install writes the partition that is not selected and switches to it, so two
installs of the same bundle leave both partitions with that bootchain. Going back to an
older bootchain means installing its bundle.

Hardware-validated 2026-10-12: `boot0` → `boot1` install, read-back, switch and boot,
then `boot1` → `boot0`; repeated 2026-10-13 with the backported upstream RAUC handler fix.

### Guards

The pre-install handler refuses, before anything is written, unless:

- `/chosen/edge,boot-source` is `emmc`, `/dev/mmcblk0` is an eMMC with `boot0` and
  `boot1`;
- EXT_CSD enables `boot0` or `boot1`, `BOOT_ACK` is off and the boot bus is 8-bit;
- the bundle's PMIC variant matches the board;
- the TF-A pin in the bundle maps to the FIP offset this system expects;
- the image is well formed: zero before BL2, the BL2 signature and a size word equal to
  the body rounded up to 4 bytes, the FIP ToC, and BL2/FIP hashes equal to the bundle's;
- the image fits the target partition;
- the U-Boot DTB in the bundle's FIP holds, as `required="conf"`, the same RSA key the
  current anchor (the FIP in the active partition) holds for each slot FIT's signer.
  A signer missing from the current anchor, or an unreadable current anchor, is a
  refusal.

### Recovery

The ROM boots only the partition EXT_CSD selects. If a newly selected bootchain does
not come up:

- **Linux still runs:** `sudo mmc bootpart enable 1 0 /dev/mmcblk0` selects `boot0`
  (`2` selects `boot1`).
- **No Linux:** SW11 to QSPI, SW1-2 OFF, stop U-Boot, then `mmc partconf 0 0 1 0`
  (`boot0`) or `mmc partconf 0 0 2 0` (`boot1`), and boot the eMMC again.
- **No working U-Boot on any medium:** SCIF Flash Writer, `EM_SECSD` and `EM_W`
  ([eMMC provisioning](../emmc/rzv2l.md)).

Both selection paths hardware-validated 2026-10-13: `bootpart enable` from Linux in
both directions, `partconf` from the QSPI U-Boot.

Before a first install, copy both partitions and the EXT_CSD dump to `/data` and off
the board:

```bash
sudo mkdir -p /data/rzv2l-boot/e7 && cd /data/rzv2l-boot/e7
sudo dd if=/dev/mmcblk0boot0 of=boot0-full.bin bs=1M
sudo dd if=/dev/mmcblk0boot1 of=boot1-full.bin bs=1M
sudo mmc extcsd read /dev/mmcblk0 | sudo tee extcsd-before.txt >/dev/null
sha256sum boot0-full.bin boot1-full.bin | sudo tee SHA256SUMS
```

From a QSPI-booted U-Boot such a copy goes back with `ext4load mmc 0:4 …`,
`mmc dev 0 1` (or `2` for `boot1`) and `mmc write … 0 0xFC00`, as in the updater's
recovery below.

### Testing

- `scripts/ci/rzv2l-bootchain-selftest.sh` runs the handler, slot hook, authorize tool
  and composer against bundles built and signed with the build's native RAUC, on a
  file-backed eMMC and a replay of RAUC's install order: authorization, mixed bundles,
  hook and handler declarations, image, variant, pin, board state, anchor and
  read-back cases.
- `scripts/ci/rauc-boot-emmc-hooks-test.sh <rauc source>` builds RAUC 1.15.2 stock and
  patched and runs its boot-emmc handler with a real hook and with the guard slot hook
  (LD_PRELOAD stand-in for the eMMC ioctls and sysfs). Stock fails the hooked cases;
  patched passes all, including "post-install fails → no EXT_CSD switch" and
  "pre-install fails → both partitions unchanged".

## rzv2l-bootloader-update (QSPI, eSD, eMMC `boot0`)

### Build

`make dev BOOTLOADER_UPDATE=1` installs `/usr/sbin/rzv2l-bootloader-update`, the
staged BL2/FIP variants under `/usr/share/rzv2l-boot/` and their `manifest.tsv`. For
out-of-band provisioning without an image rebuild:

```bash
make bootloader-package    # -> tmp/deploy/images/<machine>/rzv2l-bootloader-<machine>.tar.gz
```

The tarball holds the same artifacts, the manifest and the updater script;
`ROOT_DIR=<dir>` points the updater at an unpacked copy.

### Where each mode writes

Addresses are those TF-A reads (`plat/renesas/rz/common/plat_storage.c`,
`RZG2L_*_FIP_BASE`):

| mode | BL2 | FIP | status |
|---|---|---|---|
| `qspi` | `mtd0` (QSPI 0x0) | QSPI 0x20000 = `mtd1` + (0x20000 − `mtd1` start), derived from sysfs | hardware-validated: header-last write, restore and boot 2026-10-11; killed mid-FIP and mid-BL2 write → ROM falls to SCIF download mode, `--restore` recovers, 2026-10-12 |
| `esd` | boot SD @ 0x200 | boot SD @ 0x20000 (WIC sector 256) | hardware-validated: header-last write and boot 2026-10-13 (MBR sector and partition table unchanged) |
| `emmc` | `mmcblk0boot0` @ 0x200 (sector 1) | `mmcblk0boot0` @ 0x20000 (sector 256) | hardware-validated: header-last write and boot 2026-10-12 |

`--mode emmc` writes `boot0` only and refuses while EXT_CSD enables `boot1`; after a
RAUC bootchain install that selected `boot1`, use the RAUC slot.

### On-target usage

Run as root with an explicit mode and variant. Run long writes as a transient unit so
a dropped SSH session cannot interrupt them:

```bash
sudo rzv2l-bootloader-update --mode qspi --variant pmic --dry-run
sudo systemd-run --unit=bl-update --collect \
    /usr/sbin/rzv2l-bootloader-update --mode qspi --variant pmic --yes
journalctl -u bl-update -o cat
```

`--variant` must match the board: the SMARC EVK with the RAA215300 PMIC uses `pmic`.
A reboot activates the new bootchain; check the console for `[EDGE] BL2`,
`[EDGE] UBOOT` and the expected `SYS_LSI_MODE`.

### Guards

In addition to the shared contract, before the first write:

- one run at a time (`flock`);
- the variant equals the PMIC detected from the device tree;
- the QSPI partition labels are exactly `bl2` and `fip`, BL2 sits at QSPI 0, and the
  FIP offset is inside `mtd1` and erase-aligned;
- the device on SDHI0 matches the mode: an SD card (no `boot0`) whose partitions all
  start after the raw bootchain area for `esd`, an eMMC with `boot0` enabled, 8-bit
  boot bus and `BOOT_ACK` off for `emmc`;
- on eSD the FIP ends before the U-Boot environment;
- each target holds offset + size, and BL2 carries a valid boot-parameter header;
- the U-Boot DTB inside the candidate FIP (or the restore run's FIP) trusts the key
  behind each installed slot FIT, compared with the anchor in the FIP the board
  booted from (`/chosen/edge,boot-source`).

### Write order and backups

When BL2 or the FIP differs from the staged pair, the updater backs up both to
`/data/rzv2l-boot/backup/<run-id>/` (`<part>.img` + `<part>.meta`: target, offset,
size, SHA-256; a QSPI partition whole, because `flashcp` erases whole 4 KiB blocks),
then:

1. invalidates the BL2 header on the medium (QSPI: size word and signature programmed
   to zero; eSD/eMMC: every header copy zeroed) and reads it back;
2. writes the FIP if it differs, and reads it back;
3. writes the BL2 body, then the header last, and reads BL2 back.

Until step 3 completes the ROM rejects the medium: on QSPI it falls to SCIF download
mode for a zeroed signature, a zeroed signature + size word and an erased header, and
for a write killed during the FIP or the BL2 body (hardware-validated 2026-10-12). A
run that stops on an error prints the run id to restore; after a power cut or kill,
the newest run under `/data/rzv2l-boot/backup/` is the one. eMMC `boot0` is made writable only for
the writes and returned to read-only on every exit path.

### Rollback

```bash
sudo ls /data/rzv2l-boot/backup/
sudo rzv2l-bootloader-update --restore <run-id> --dry-run
sudo rzv2l-bootloader-update --restore <run-id> --yes
```

A restore writes the run's pair back through the same guards and order, after backing
up what it replaces (its own run). A run that holds one part is completed from the
medium. A part with an `.img` but no `.meta`, or the reverse, is refused as a corrupt
backup, and a `.meta` naming any location other than the bootchain locations above is
refused.

### Recovery

When the bootchain on the selected medium no longer boots, set SW11 to another medium
that holds a working bootchain (an SD written from the WIC carries one), boot Linux,
and `--restore` or re-run the update.

A Linux booted off the SD cannot reach the eMMC (SW1-2). A broken eMMC boot partition
is restored from the U-Boot console of a working bootchain (QSPI with SW1-2 OFF, or the
eMMC while its U-Boot still runs), from a full image kept on the eMMC's `/data`
partition:

```
=> ext4load mmc 0:4 0x58000000 /rzv2l-boot/e7/boot0-full.bin
=> hash sha256 0x58000000 ${filesize}          # compare with the saved hash
=> mmc dev 0 1                                  # hardware partition boot0 (2 = boot1)
=> mmc write 0x58000000 0 0xFC00                # 0xFC00 blocks = the 31.5 MiB partition
=> mmc read 0x60000000 0 0xFC00
=> hash sha256 0x60000000 0x1F80000             # must equal the image hash
=> mmc dev 0 0
=> mmc partconf 0 0 1 0                         # select boot0
=> reset
```

Hardware-validated 2026-10-13 from the QSPI U-Boot: a backup written into an erased
`boot1` (`mmc dev 0 2`), read back, selected with `partconf 0 0 2 0` and booted.

Without such a medium, re-flash BL2 and FIP with the Renesas SCIF Flash Writer
(`Flash_Writer_SCIF_RZV2L_SMARC_PMIC_DDR4_2GB_1PCS.mot` for the PMIC board) in SCIF
download mode.

### Testing

`scripts/dev/rzv2l-bootloader-failure-suite.sh` runs on the board and feeds the
updater every condition it must refuse: corrupt artifact, wrong manifest hash, wrong
mtd label, wrong variant, oversized image, bad QSPI FIP address, wrong SD/eMMC
medium, FIP anchor that does not trust the slot FITs' key, not root, operator "no",
missing, corrupt, half-present or redirected restore run:

```bash
ssh devel@<board> 'bash -s -- --restore-run <run-id>' \
    < scripts/dev/rzv2l-bootloader-failure-suite.sh
```
