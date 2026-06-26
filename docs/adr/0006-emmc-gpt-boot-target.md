# ADR-0006: eMMC/GPT boot target with systemd-repart `/data` growth

- Status: Accepted
- Date: 2026-06-23

## Context

The platform grows `/data` to fill the storage device on first boot (a small
seed partition ships in the image; the rest of the card is claimed at runtime —
see [ADR-0004](0004-persistent-state-architecture.md)). The original mechanism
is a shell oneshot (`rauc-grow-data-partition.service` →
`grow-data-partition.sh`) that drives `parted` to resize the partition and
`resize2fs` to grow the filesystem.

Replacing that bespoke script with the declarative, upstream-maintained
`systemd-repart` is desirable: it retires the several-hundred-line shell program
in favour of a lean dispatcher, and `systemd-repart` natively relocates the GPT
backup header to the true end of the device after a small image is written to a
large card — the exact step the shell script needed `sgdisk -e` for.

`systemd-repart` operates **only on GPT** disks. The default RZ/V2L SD layout is
**MBR**, and that is not incidental: in **eSD boot** the SoC mask ROM reads BL2
from raw sector 0 of the boot medium (`bl2_bp_esd…` occupies the leading
sectors), which collides with a GPT protective MBR + primary header at LBA 0–33.
On the boot SD, BL2-at-sector-0 and a valid GPT cannot coexist, so the eSD path
is structurally pinned to MBR and cannot adopt `systemd-repart`.

**eMMC boot mode** removes that collision. The mask ROM reads BL2 from the eMMC
hardware boot partition `mmcblk0boot0`, not the user area. With BL2 (and FIP)
relocated into `boot0`, the eMMC **user area** carries no raw bootloader region
and is free to hold a clean GPT — the precondition `systemd-repart` needs.

## Decision

Add an `EDGE_BOOT_TARGET` capability toggle (`esd` | `emmc`, default `esd`) in
`edge-ab-image.bbclass`. The eSD/MBR path is unchanged and remains the default
and the recovery path; `emmc` is opt-in and selects the GPT + `systemd-repart`
layout. The items below are emmc-specific except item 2 (the grow mechanism),
which is unified and ships for both layouts.

1. **GPT user-area image.** `edge-rzv2l-emmc.wks.in` lays out a pure GPT
   (`bootloader --ptable gpt`) with no raw bootloader region — BL2 and FIP live
   in `mmcblk0boot0`, written at provisioning, never by WIC. The machine overlay
   (`kas/machines/rzv2l.yml`) maps `WKS_FILE` to this `.wks.in` when
   `EDGE_BOOT_TARGET=emmc`, else the eSD `.wks.in`.

2. **One grow mechanism, dispatched on the partition table.** A single
   `edge-grow-data` recipe ships `edge-grow-data.service` (a oneshot ordered
   *before* `data.mount`) and the `edge-grow-data.sh` dispatcher: on GPT it runs
   `systemd-repart --dry-run=no` (grows `/data` and relocates the backup header,
   so **no `sgdisk`**); on MBR it runs `parted resizepart`. Both then share an
   `e2fsck` + `resize2fs` + `tune2fs -m 0` tail. `/data` carries a distinct GPT
   type GUID (`00FB7005-AB51-4206-9D4A-11B68E508D3A`), supplied by
   `/etc/repart.d/50-data.conf`, so `systemd-repart` matches only it (the
   rootfs/boot partitions keep the generic Linux type and are left foreign). A
   `/boot/.edge-data-grown` stamp makes it first-boot-only.

3. **`systemd[repart]` + `openssl` PACKAGECONFIG** are enabled unconditionally:
   the unified grow may call `systemd-repart` on either build, and `openssl`
   (which `repart` requires) also backs crypto `systemd` features
   (`systemd-creds`, hashing) wanted platform-wide.

4. **One growth package, installed unconditionally.** `edge-ota-rauc.inc`
   installs `edge-grow-data` regardless of `EDGE_BOOT_TARGET`; the dispatcher
   picks the GPT (`systemd-repart`) or MBR (`parted`) path at runtime.

5. **GPT-aware RAUC slot identity.** `edge-slot-udev` ships PARTLABEL-keyed
   rules (`ENV{ID_PART_ENTRY_NAME}`) for `emmc` and the `mmcblk0pN` rules for
   `esd`; both produce the same `/dev/disk/by-rauc-slot/*` aliases RAUC's
   `system.conf` consumes, so the OTA abstraction ([ADR-0005](0005-image-class-ota-backend.md))
   is untouched.

6. **Provisioning is a two-write, one-time flow.** BL2+FIP are written to
   `mmcblk0boot0` via the Renesas Flash Writer over the SCIF serial port.
   The GPT user-area image is then written via U-Boot `ums` (exposing the
   eMMC as a USB mass-storage device to a provisioning host) or from a
   provisioning Linux environment with `bmaptool`. The bootloader binaries
   are boot-device-agnostic; TF-A reads a boot-source register to
   determine whether to load BL2 from SD or eMMC `boot0`.

## Rationale

- **Why GPT at all.** `systemd-repart` is GPT-only. The payoff is deleting the
  bespoke grow script and getting backup-GPT-header relocation for free — the
  step that previously failed because `sgdisk` (gptfdisk) is not in the image.

- **Why eMMC boot unlocks it.** It is the only RZ/V2L boot mode that takes BL2
  out of user-area sector 0. eSD/MBR is structurally incompatible with GPT; no
  amount of offset tuning reconciles BL2-at-sector-0 with a GPT primary header.

- **Why a toggle, not a migration.** The eSD/MBR path is proven and is the
  recovery path (a bad eMMC provision is recoverable by reselecting SD boot). It
  stays the default; `emmc` is additive and changes nothing for a build that
  does not opt in (verified: the eSD image is byte-identical with the toggle
  absent).

- **Why `repart` + `resize2fs`, not `repart` alone.** `repart.d`'s
  `GrowFileSystem=` only sets a GPT flag bit (Discoverable-Partitions spec) and
  has no effect on explicit fstab mounts — it does not resize the filesystem.
  The partition geometry (the part that needed `sgdisk`) is `repart`'s job; the
  ext4 grow stays an explicit `resize2fs`.

- **Why a custom `/data` type GUID.** `systemd-repart` matches partitions by GPT
  type. A distinct GUID makes `/data` the sole match while the rootfs/boot
  partitions remain "foreign" and untouched; it also keeps
  `systemd-gpt-auto-generator` from auto-mounting `/data` (the GUID is not a
  discoverable type), avoiding any conflict with the fstab `LABEL=data` mount.

## Consequences

**Positive.**

- The ~300-line bespoke grow script is replaced on **both** layouts by one lean
  dispatcher; GPT backup-header relocation comes free from `systemd-repart` (no
  `sgdisk`), and the shared `resize2fs`/`tune2fs` tail removes the drift risk of
  maintaining two separate grow paths.
- The eSD path is unchanged — same WKS, same MBR grow, same slot rules, same raw
  U-Boot env offset. Opting out costs nothing.
- The RAUC OTA contract is preserved across the layout change: slots are still
  addressed through `/dev/disk/by-rauc-slot/*`, now backed by PARTLABEL identity
  that is robust to GPT partition renumbering.
- A future model-store / DRP-AI partition is an additive GPT partition plus a
  `repart.d` drop-in, not a new bespoke resizer.

**Negative.**

- Provisioning is a two-write flow (boot0 + user area) and needs a one-time
  serial Flash Writer pass for a blank eMMC. Heavier than the single SD image
  write of the eSD path. Documented, but it is real operational cost.
- `EDGE_BOOT_TARGET` is a cross-cutting global: it influences the WKS, the slot
  udev rules, and the bundle build. The coupling is intentional and gated, but a
  reader must follow the toggle through several files. (The grow mechanism is no
  longer among them — it dispatches at runtime, not at build time.)
- Two WKS files per board (`edge-rzv2l.wks.in`, `edge-rzv2l-emmc.wks.in`) for
  one board — a boot-target dimension on top of the per-board WKS rule in
  ADR-0005.

## Scope and non-scope

**In scope.** The `EDGE_BOOT_TARGET` toggle, the GPT eMMC WKS, the unified
`edge-grow-data` dispatcher (GPT `systemd-repart` / MBR `parted` + shared
`resize2fs`/`tune2fs`), the PARTLABEL slot rules, the two-write provisioning
flow, and the boot-target threading through the image and bundle builds.

**Out of scope.**

- Migrating the eSD/MBR path to GPT. It cannot adopt GPT (BL2 at sector 0) and
  remains the default and recovery path.
- A second board's eMMC layout. Boards differ in bootloader offsets; each gets
  its own `.wks.in`. The mechanism (repart drop-in, slot rules, toggle) is
  reusable; the partition map is not.
- U-Boot environment relocation. The eMMC keeps the raw env in the user-area gap
  below `/boot` (`CONFIG_SYS_MMC_ENV_DEV=0`), so `fw_setenv` and
  `rauc-uboot-env-init` apply unchanged — no GPT env partition.
- Model-store / DRP-AI partition wiring (deferred with ADR-0005).

## Revisit triggers

- A board whose mask ROM can read BL2 from a GPT-compatible offset (no
  sector-0 collision) would let the eSD-class path adopt GPT directly,
  collapsing the toggle for that board.
- If `systemd-repart` gains a maintained path to grow the filesystem itself for
  fstab mounts, the explicit `resize2fs` call in `edge-grow-data.sh` becomes
  redundant on the GPT branch.
- A model-store partition lands: fold it into the eMMC WKS + a `repart.d`
  drop-in and revisit whether the growth policy needs per-partition weights.

## Validation

Hardware-validated on the RZ/V2L SMARC EVK, both layouts:

- **eMMC/GPT** (booted from a GPT user area): boot0 carries BL2+FIP; the user
  area is a clean GPT; the dispatcher takes the `systemd-repart` branch (grows
  `/data` + relocates the backup header), then `resize2fs`/`tune2fs`;
  `/dev/disk/by-rauc-slot/*` resolve via PARTLABEL; an OTA round-trip installs
  and boots slot B.
- **eSD/MBR** (default SD boot): the dispatcher takes the `parted` branch
  (`resized MBR partition … to 100%`), then the same fs tail; the on-target
  smoke test is clean (0 fail).

SELinux MCS and the persistence binds are intact on both. The eSD image is
byte-identical with the toggle absent (regression-checked via `bitbake-getvar`).

## References

- [systemd-repart(8)](https://www.freedesktop.org/software/systemd/man/latest/systemd-repart.html) — declarative partition growth / creation.
- [Discoverable Partitions Specification](https://uapi-group.org/specifications/specs/discoverable_partitions_specification/) — GPT type GUIDs and the `GrowFileSystem=` flag.
