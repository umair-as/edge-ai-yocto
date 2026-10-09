# ADR-0014: Bootchain update is a per-board capability (RZ/V2L BL2/FIP backend first)

- Status: Accepted
- Date: 2026-10-07
- Relates: [ADR-0011](0011-per-board-kernel-base.md) (per-board property precedent),
  [ADR-0005](0005-image-class-ota-backend.md) (RAUC rootfs OTA),
  [ADR-0006](0006-emmc-gpt-boot-target.md) (RZ/V2L BL2/FIP placement),
  [ADR-0008](0008-runtime-rootfs-verity.md)

## Context

The RAUC A/B flow updates the rootfs slots and the per-slot kernel FIT. It does not
touch the bootchain — the firmware that runs before the kernel — which lives outside
the RAUC slot layout in board-specific storage. Bootchain security fixes (U-Boot,
TF-A, OP-TEE, vendor firmware) therefore cannot reach a provisioned board through the
rootfs OTA, and need a separate delivery path.

This is a multi-board platform. The bootchain and the way it is stored and rewritten
differ **fundamentally** per board — there is no single mechanism:

- **RZ/V2L (Renesas):** a BL2 boot-parameter image plus a FIP (TF-A BL31, OP-TEE
  BL32, U-Boot BL33), in single-copy storage — QSPI flash (`mtd` `bl2`/`fip`), eSD
  raw offsets, or the eMMC hardware boot partition. Recovery is the SCIF Flash Writer
  over serial.
- **Raspberry Pi 5:** an EEPROM-resident bootloader (updated with `rpi-eeprom-update`)
  plus VideoCore firmware and U-Boot carried as *files* on the FAT boot partition.
  No BL2/FIP, no `mtd`, no raw offsets, no Flash Writer.
- **Future (i.MX93, TI AM64x, …):** different again — e.g. a combined `imx-boot`
  /SPL+U-Boot image at an SD/eMMC offset with `uuu` recovery, or TI `tiboot3` /
  `tispl` / `u-boot.img` on a FAT boot partition. Each brings its own layout, tooling
  and recovery.

The bootchain storage on RZ/V2L (and on several of these) is single-copy with no A/B
redundancy and no runtime rollback: an interrupted or wrong write is not self-healing.

## Decision

**Treat bootchain update as a per-board capability, not a shared mechanism** — the
same way [ADR-0011](0011-per-board-kernel-base.md) treats the kernel base. The common
surface is intent and wiring; the implementation is per board:

- A board-neutral **intent**: `EDGE_ENABLE_BOOTLOADER_UPDATE` (Makefile
  `BOOTLOADER_UPDATE=1`) means "install this board's bootchain updater, if it has
  one." It is machine-gated, so it is a no-op on a board with no backend, and the
  Makefile warns when it is set for such a board.
- A **per-board backend**, named for its board and scoped to it: a recipe with
  `COMPATIBLE_MACHINE` set, under that board's `dynamic-layers/`, installed via an
  `IMAGE_INSTALL:append:<machine>`. A new board adds its own backend under the same
  intent flag; it never generalises another board's.

The first backend is **RZ/V2L**: `rzv2l-bootloader-update`, a guarded, attended,
operator-run tool (and a `make bootloader-package` host package) that rewrites BL2 and
FIP for `qspi`/`esd`/`emmc`. It is **deliberately separate from RAUC**: the capability
to build and apply a new bootchain is the requirement; unattended delivery is not, and
is deferred (see Open questions).

The second backend is **Raspberry Pi 5**: `edge-rpi-eeprom`, an operator-run wrapper
over `rpi-eeprom-update` that stages an EEPROM bootloader image to `/boot` for the
firmware to self-flash on reboot. Detecting the board on this board's signed-FIT
mainline boot needs the board revision in the kernel device tree, which a U-Boot patch
forwards from the firmware's `/system` node; see
[`bootchain/raspberrypi5.md`](../dev/bootchain/raspberrypi5.md). Updating the
FAT-partition boot files (U-Boot, DTB, `config.txt`) are the operator-run
`edge-rpi-bootfiles-update` (manifest + backup/`--restore`, a FAT-file sibling of
`rzv2l-bootloader-update`); RAUC-integrated or unattended delivery remains open.

RZ/V2L brick-risk is reduced by a guard chain that runs for every artifact before the
first byte is written: root + explicit mode/variant; variant matches the PMIC detected
from the device tree; artifact SHA-256 == manifest; QSPI `mtd` label check (refuse the
wrong region); target addresses taken from what TF-A reads (`RZG2L_*_FIP_BASE`), not
from partition starts; capacity/overflow check; skip if the target already holds this
content; then back up the current content (a QSPI partition whole) to persistent
`/data` with its target, offset, size and hash; write, sync, read back, re-hash.
`--restore <run-id>` writes a backup back through the same chain. Residual
power-loss-mid-write is recovered from another boot medium or the Flash Writer — the
accepted backstop, not a no-risk claim.

All three modes are hardware-validated (write, boot from the medium; `qspi` and `emmc`
also restore, QSPI rollback and roll-forward; 2026-10-07). The eMMC addresses are those
of [ADR-0006](0006-emmc-gpt-boot-target.md).

## Consequences

- Bootchain CVE fixes become deliverable to a provisioned RZ/V2L board without
  re-imaging. RPi5 and future boards gain the same capability only when their own
  backend is written — this ADR does not pretend otherwise.
- `rzv2l-bootloader-update`, its ADR scope, its offsets, its Flash-Writer recovery and
  its `bl2_bp`/`fip` artifacts are **RZ/V2L-only**. Nothing here is a template for
  another board beyond the intent-flag + machine-gated-backend pattern.
- The tool is off by default and present only on RZ/V2L images built with the flag; a
  stock image of any board carries no brick-capable tool.
- Applying an update is a deliberate operator action with a reboot; no change to RAUC.
- **A bootchain is only valid together with the FIT it must verify.** A U-Boot whose
  control DTB lacks the key the installed FIT is signed with rejects it on every boot
  and resets in a loop, rewriting the U-Boot environment each time. Rolling the
  bootchain back across a FIT-key change therefore makes the board unbootable from that
  medium; rollback targets are limited to builds that trust the current FIT key.
- The medium the ROM boots from is set by board switches and is not visible from the
  running system's partition list; it is confirmed from the BL2 console output.

## Alternatives considered

- **A single cross-board bootloader-update mechanism.** Rejected as incoherent: BL2/FIP
  vs EEPROM+files vs SPL-at-offset share no storage model, tooling or recovery. A
  shared abstraction would be a thin wrapper over per-board code that still has to
  exist, and would invite applying one board's offsets to another.
- **RAUC-integrated bootloader slot now.** RAUC supports bootloader/raw slot types
  (`boot-raw-fallback`, `boot-emmc`, MBR/GPT switch). Deferred, not rejected: on the
  single-copy RZ/V2L QSPI target an unattended RAUC write carries the manual tool's
  brick-risk without the operator in the loop. It is the natural Phase 2 on a redundant
  target, and is itself per-board.
- **One-time provisioning only (status quo).** Rejected: cannot ship a fix to a fielded
  board.

## Open questions (Phase 2, each per-board)

- **Unattended / RAUC-integrated delivery** on a redundant target: RZ/V2L eMMC
  `boot0`/`boot1` via `boot-emmc`, or a two-copy QSPI region via `boot-raw-fallback`;
  RPi5 via the boot-partition files + `rpi-eeprom`. Each board, its own design.
- **Anti-rollback.** Treat the board's bootchain as one version-floored update unit
  with a boot-enforced monotonic floor, so the updater cannot install an older security
  version. Prerequisite for unattended delivery; mechanism is per board.
- **Signed-FIT verifier coupling (RZ/V2L).** Adding an image reference to a FIT config
  without extending the signed set fails verification at boot under the current U-Boot
  verifier; a deploy-time assertion that config image properties are a subset of the
  signed images belongs with this track.
