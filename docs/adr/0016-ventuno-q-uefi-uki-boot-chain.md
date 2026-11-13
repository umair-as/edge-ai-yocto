# ADR-0016: VENTUNO Q joins as a `uefi-uki` boot-chain family

- Status: Accepted
- Date: 2026-10-19
- Amended: 2026-10-28 — firmware variable persistence (Context); the ESP
  bootstrap copy is kept (§6)
- Amended: 2026-11-11 — the board moves to the `custom` variant with a slot
  activation mechanism; no EFI variable is written (§6)
- Amended: 2026-11-13 — the `efi` variant is rejected and removed; `custom`
  is the family's only RAUC backend (§6)
- Relates: [ADR-0005](0005-image-class-ota-backend.md) (RAUC OTA backend),
  [ADR-0008](0008-runtime-rootfs-verity.md) (runtime rootfs dm-verity),
  [ADR-0011](0011-per-board-kernel-base.md) (per-board kernel base),
  [ADR-0014](0014-bootchain-update-mechanism.md) (per-board bootchain update)

## Context

The Arduino VENTUNO Q (ABX00181) is a Qualcomm Dragonwing IQ8 board: a QCS8275
("Monaco") SoC on the "Monza" SoM, 64 GB eMMC as the only boot medium, and an
STM32H5 co-processor. Its BSP is `meta-qcom-arduino` (machine `ventuno-q`) on
`meta-qcom`, both on the `wrynose` branch.

### What runs before Linux

The boot chain is entirely Qualcomm firmware up to the OS loader:

```
PBL (ROM) → XBL → TZ, Gunyah hypervisor, AOP, CPUCP, … → Qualcomm UEFI (EDK II)
          → OS loader on the ESP → Linux at EL1 under Gunyah
```

- **Firmware layout.** The firmware sits in `_a`/`_b` partition pairs in the
  eMMC user area. The CDT sits in boot partition 1.
- **The OS side has no A/B.** It is a single `efi` partition (p69, 512 MiB
  VFAT), a single `persist` (p70) and a single `system` (p71, the rest of the
  device).
- **DTB loading.** UEFI loads the DTB it hands to Linux from the `dtb_a`
  partition. It first tries a FIT container (`qclinux_fit.img`), then falls back
  to a legacy multi-DTB blob.

### What a factory unit shows (observed 2026-10-12 and 2026-10-16)

- **No fuses.** XBL reports `Secure Boot: Off`; the unit is unfused.
- **No RPMB.** The eMMC RPMB key is not programmed: the RPMB counter read
  returns result 7, "Authentication key not yet programmed" in the JESD84 result
  table.
- **No UEFI Secure Boot keys.** UEFI Secure Boot is off, in setup mode, with no
  PK/KEK/db enrolled.
- **Firmware banks match.** `xbl`, `xbl_config` and `uefi` are byte-identical
  in both banks. `tz` and `hyp` hold identical ELF content in both banks; their
  whole partitions differ only past the ELF end.
- **The factory OS writes `dtb_a`.** `dtb_a` holds the DTB of the factory OS's
  current kernel; `dtb_b` still holds the image's original DTB. A factory OS
  kernel update therefore rewrites `dtb_a`.
- **Linux can write EFI variables.** Linux sees `efivarfs` read-write, with
  `Boot0000`, `BootOrder` and `BootCurrent`.
- **Runtime-written variables persist through a file on the ESP.** The firmware
  exposes `RTStorageVolatile` (`VolatileVars.bin`) and `VarToFile`, the
  file-backed variable-store mechanism EBBR describes as non-normative. Linux
  writes reach firmware memory only; oe-core's efivar copies `VarToFile` over
  `VolatileVars.bin` after each libefivar write (`efibootmgr`, `efivar`), and the
  firmware loads that file at boot.
- **That store keeps only the current boot's writes (observed 2026-10-28).** The
  firmware starts `VarToFile` empty on every boot, so the copy after the first
  write of a boot holds only the variables written in that boot. A boot that
  wrote only `BootOrder` (RAUC's mark-good) left a store with only `BootOrder`;
  `Boot0001`/`Boot0002` were gone at the next power-on. Writes the firmware makes
  during boot, including consuming `BootNext`, never reach the file. Both match
  meta-qcom issues [#2810](https://github.com/qualcomm-linux/meta-qcom/issues/2810)
  and [#2809](https://github.com/qualcomm-linux/meta-qcom/issues/2809), reported
  on QCS9075 with the same firmware line.
- **The firmware boots its own entries.** `Boot0000` ("Ubuntu",
  `\EFI\ubuntu\shimaa64.efi`) carries no load options. `BootOrder` is `0007` and
  `BootCurrent` is `0006`, and neither `Boot0006` nor `Boot0007` is visible in
  `efivarfs`: the factory boot runs through entries the firmware creates and Linux
  cannot see.
- **The factory GPT is image-constant.** It is the one in Arduino's published
  factory image, with the same partition and disk GUIDs, apart from `system`
  growing to the end of the device on first boot.
  - It has 72 entry slots, 71 in use.
  - The first usable LBA is 34, so a 128-entry array (LBA 2–33) fits without
    moving any partition, at both ends of the device.

### What Qualcomm documents (accessed 2026-10-16)

- **UEFI Secure Boot needs RPMB.** "Replay protected memory block (RPMB)
  provisioning is mandatory for UEFI secure boot enablement."
  ([enable-uefi-secure-boot](https://dragonwingdocs.qualcomm.com/System/Security/enable-uefi-secure-boot.md))
- **Capsule rollback needs RPMB too.** A capsule update can start with RPMB
  unprovisioned, but "The trial boot and rollback features are available only
  when the system sets up RPMB."
  ([capsule trial boot](https://dragonwingdocs.qualcomm.com/System/Boot/update-capsule-and-trial-boot-rollback-for-base-and-variants.md))
- **The RPMB key is one-time.**
  - "If you provision the RPMB with test keys on non-secure devices, you can't
    re-provision it with a device key when enabling Qualcomm secure boot on the
    device."
    ([set-up-the-capsule](https://dragonwingdocs.qualcomm.com/System/Boot/set-up-the-capsule.md))
  - "The key enrollment using systemd-boot manager to store keys into RPMB is a
    one-time operation. After successful key enrollment, the reprovisioning and
    updating of UEFI secure boot keys isn't possible."
    ([enable-uefi-secure-boot](https://dragonwingdocs.qualcomm.com/System/Security/enable-uefi-secure-boot.md))
- **Fused secure boot is one-time.** It blows QFPROM fuses, "a one-time,
  irreversible process", and should be done "on a device that's not RPMB
  provisioned".
  ([enable-secure-boot](https://dragonwingdocs.qualcomm.com/System/Security/enable-secure-boot.md))
- **The BSP's own OTA has no partition A/B.** It ships no RAUC integration. Its
  OS update path is OSTree: "The `system.img` file contains the rootfs, including
  … `/ostree/deploy`", the UKI and loader configuration live in `efi.bin`, and
  "`systemd-bless-boot.service` marks the new config as good".
  ([capsule and OSTree](https://dragonwingdocs.qualcomm.com/Key-Documents/Yocto-Guide/update-firmware-and-os-on-qualcomm-linux-using-capsule-and-os-tree-mechanisms.md))
- **Every BSP flash rewrites all firmware partitions.** The BSP's flash package
  (`qcomflash`) contains every firmware partition, so any flash with it rewrites
  them all. Its partition table also differs from the factory one from p23
  onward.

### Why this needs a decision

The platform implements one boot-chain family, `uboot-fit`: firmware → U-Boot →
a signed FIT verified against a key in U-Boot's control DTB → a raw U-Boot
environment as RAUC's boot-count store.
- `edge-image.bbclass` refuses any other `EDGE_BOOT_CHAIN`, stating that another
  family "needs its own trust anchor and boot-count store".
- `rauc-conf-edge` renders `bootloader=uboot`.

On both existing boards, authentication starts at U-Boot's embedded FIT key,
not at a hardware root: the ROM does not verify U-Boot
([U-Boot hardening](../security/uboot-hardening.md); ADR-0008 makes no
hardware-rooted claim). This ADR keeps that honesty and gives it a name that
applies to all three boards.

### Constraints this design works within (decided 2026-10-16)

1. **Secure boot: neither.** No fusing, no RPMB provisioning, no UEFI key
   enrollment. The unit stays reversible.
2. **Boot-chain family:** a new `uefi-uki` family. The Qualcomm firmware and
   EDK II stay untouched. systemd-boot + UKI on the ESP. The factory GPT
   p1–p70 stays as it is, and the slots are carved from the `system` region.
3. **RAUC backend:** `custom` over systemd-boot boot counting (§6, amended
   2026-11-11); `efi` stays selectable.
4. **No `qcomflash` full flash in v1.**
5. **`dtb_a`/`dtb_b`:** the OS may write them, and only under §7's fallback.
6. **Qualcomm binaries are fetch-only.** The rootfs carries Qualcomm firmware,
   so every image and bundle built for this board contains it; none is
   published.
7. **Branch:** `meta-qcom-arduino` `wrynose`.
8. **STM32H5:** Linux drivers only; the MCU firmware stays factory.

## Decision

### 1. A second boot-chain family, `uefi-uki`

`EDGE_BOOT_CHAIN = "uefi-uki"` means:
- Qualcomm firmware and UEFI, which this repo neither builds nor writes, load a
  **UKI built by this repo**.
- The UKI carries the kernel, the kernel command line (including the dm-verity
  table and root hash) and the DTB.
- The kernel mounts a dm-verity rootfs from an A/B slot.
- Slot selection and the boot-count store belong to the UEFI side: EFI boot
  variables, or systemd-boot's boot-counting file names (§6). The U-Boot
  environment plays no part.

`uboot-fit` boards are unaffected. The family is selected per board in the
board include, like every other board fact.

### 2. Trust-anchor levels, applied to all three boards

**Anchor** means the boot stage that verifies a signature covering the kernel,
its command line and the rootfs root hash. Three levels are defined:

| Level | Meaning | Boards |
|---|---|---|
| `hardware` | The anchor stage is itself verified by a chain rooted in the SoC ROM (fuses or OTP key) | none |
| `loader-key` | A boot stage built by this repo verifies the signature with a key built into that stage. The stage changes only through a signed bundle (ADR-0014, ADR-0015), but the ROM does not verify it | rzv2l, raspberrypi5 (U-Boot FIT key) |
| `none` | No stage verifies the artifact that carries the root hash | ventuno-q under decision 1 |

**What separates `loader-key` from `none`.** Against an attacker with offline
access to the storage, both fall. The difference is at runtime: on `none`, a
root process can make the next boot use a different root hash by writing one EFI
variable (a boot entry's load options), without touching any partition. On
`loader-key` it has to rewrite the loader itself.

The gate in `edge-image.bbclass`:
- **Board fact.** Each board include declares `EDGE_BOOT_ANCHOR` alongside
  `EDGE_BOOT_CHAIN`.
- **Combination check.** The image fails when the pair is not one of
  `uboot-fit/loader-key`, `uboot-fit/hardware`, `uefi-uki/none` or
  `uefi-uki/hardware`.
- **Prod tier.** A `prod`-tier image fails on `EDGE_BOOT_ANCHOR = "none"`
  unless the board include also sets `EDGE_ALLOW_UNANCHORED_VERITY = "1"`. The
  `ventuno-q` include does not set it, so a prod image for this board fails.
- **This prod rule is added by this ADR, not given by the constraints.** It is
  the one place the ADR adds policy.
- **Gate message for `none`:** "dm-verity on this image detects corruption of
  the rootfs; it does not authenticate it: no boot stage verifies the root
  hash."

**Effect on the other boards:** rzv2l and raspberrypi5 declare `loader-key` and
build exactly as today.

### 3. Signed artifacts, from ROM to rootfs

| Artifact | Signed by | Verified by | Location | Changed by OTA |
|---|---|---|---|---|
| PBL | — (mask ROM) | — | SoC | no |
| XBL, `xbl_config` | Qualcomm | PBL, only on a fused part; this unit is unfused | `xbl_a`/`xbl_b`, `xbl_config_a`/`_b` | no |
| TZ, Gunyah hyp, AOP, CPUCP, devcfg, QUP fw, … | Qualcomm | XBL: segment hash checks are logged at boot; signature enforcement depends on fuses | `_a`/`_b` firmware banks | no |
| UEFI (EDK II, `uefi.elf`) | Qualcomm | XBL, as above | `uefi_a`/`uefi_b` | no |
| CDT | vendor board data, unsigned | — | eMMC boot partition 1 | no |
| `dtb_a`/`dtb_b` combined DTB | unsigned | — (loaded by UEFI) | FAT partitions in the firmware bank set | no; written only under §7's fallback |
| systemd-boot (custom variant) | built here, unsigned | — (UEFI Secure Boot off) | ESP `\EFI\BOOT\BOOTAA64.EFI` | no (provisioning only) |
| UKI per slot: kernel, `.cmdline` with verity root hash, `.dtb`, `.osrel` | built here, unsigned | — (UEFI Secure Boot off) | `\EFI\BOOT\BOOTAA64.EFI` on `efiA`/`efiB` (efi) or ESP `\EFI\Linux\` (custom) | yes, the inactive slot's UKI |
| Bootstrap copy of slot A's UKI (efi) | built here, unsigned | — (UEFI Secure Boot off) | ESP `\EFI\BOOT\BOOTAA64.EFI` and `\EFI\ubuntu\shimaa64.efi` | no; written at install and kept (§6) |
| rootfs `ext4.verity` | hash tree, root hash in that slot's UKI | kernel dm-verity, at every read | `rootfsA`/`rootfsB` | yes |
| kernel modules | repo module-signing key | kernel module signature check | rootfs | yes |
| Qualcomm DSP firmware (`.mbn`) | Qualcomm | loaded through remoteproc; who verifies it, and whether that depends on fuses, is not established here | rootfs `/lib/firmware` | yes, with the rootfs |
| RAUC bundle | repo bundle key (CMS) | RAUC, against the keyring in the running rootfs | transport only | is the OTA unit |

**What the table shows.**
- The first signature this repo controls that is checked at boot is the module
  signature, inside an already-running kernel.
- The verity root hash travels in an unsigned UKI, which is §2's `none`.
- The RAUC bundle signature protects delivery and install, not boot.

### 4. Partition layout

The factory GPT is kept for p1–p70. Their contents are untouched, except two
partitions the OS already owns (see the bullet after the table):

| # | Name | Size | Type GUID | Content |
|---|---|---|---|---|
| 1–68 | factory firmware and unit data | factory | factory | untouched |
| 69 | `efi` | 512 MiB (factory) | ESP | the unit's own firmware-maintained files, plus the bootstrap UKI (efi) or the loader and UKIs (custom) |
| 70 | `persist` | factory | factory | untouched |
| 71 | `efiA` | 128 MiB | `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` (basic data, not ESP) | an empty file system (the rejected efi variant held slot A's UKI here) |
| 72 | `efiB` | 128 MiB | same | an empty file system (the rejected efi variant held slot B's UKI here) |
| 73 | `rootfsA` | 8 GiB | `0FC63DAF-8483-4772-8E79-3D69D8477DE4` | `ext4.verity` |
| 74 | `rootfsB` | 8 GiB | same | `ext4.verity` |
| 75 | `data` | remainder of the device | `00FB7005-AB51-4206-9D4A-11B68E508D3A` | `/data`, as on the other boards |

- **The GPT itself is rewritten.** It goes from 72 to 128 entry slots, at both
  ends of the device: the protective MBR (LBA 0), the primary header and array
  (LBA 1–33), and the backup array and header at the end. Entries 1–70 are
  copied byte for byte from the unit's own GPT, after checking that p69, p70 and
  p71 are the factory `efi`, `persist` and `system`.
- **Two OS-owned partitions inside p1–p70 are written:**
  - `efi` (p69), which holds the factory OS's loader today;
  - `dtb_a`/`dtb_b`, only under §7's fallback.
- **The factory `system` partition and its OS are replaced.**
- **Starts.** p71 starts at the factory `system` start (LBA 7141376). Every
  start stays on the factory 128 KiB alignment.
- **Slot size.** 8 GiB instead of the platform default of 4096 MB leaves room
  for the Qualcomm DSP/NPU userspace; the fixed size is recorded in the board
  include. At decision time (2026-10-16) the `edge-image-dev` `ext4.verity` for
  this board was 3 517 140 992 bytes. The UKI task fails the build when the
  `ext4.verity` exceeds the slot.
- **Why `efiA`/`efiB` exist in both variants.** The GPT does not depend on the
  backend, so the bench result cannot force a re-partition.
- **Why `efiA`/`efiB` are not typed as ESPs.** RAUC's integration guide warns
  that firmware may auto-create boot entries for partitions carrying the ESP
  type GUID.

**Installation without touching firmware.** v1 installs through EDL with `qdl`
(BSD-3-Clause, from `meta-qcom`):
- **Rawprogram/patch set.** It is generated by this repo, not `qcomflash`.
- **What it writes:**
  - the primary GPT (LBA 0–33);
  - p69 and p71–p75;
  - the backup GPT.
- **What it leaves alone:** p1–p68, p70, boot partition 1 (CDT) and boot
  partition 0.
- **Built on the host from the unit's own data.** The GPT and the ESP image
  are assembled from a dump of the unit's primary GPT and p69, plus the payload
  this repo builds. No firmware-side partition content comes from the build.
- **The ESP is written as a whole image.** `qdl` writes p69 as a single
  partition image, so the image starts from the unit's own p69, which keeps the
  files the firmware maintains there (`Persisted_Capsules.bin`,
  `VolatileVars.bin`). The files the build lists for the ESP are added to it:
  the bootstrap UKI (efi) or systemd-boot, `loader.conf` and both slot UKIs
  (custom, §6). Writing p69 therefore also resets the runtime-written EFI
  variables to that file's content.
- **ESP-only restore** (`ventunoq-flash.py flash --only esp`). Writing p69 alone
  from an install set restores the ESP's loader, `loader.conf`, variable store
  and the set's two slot UKIs, and leaves p71–p75 untouched (hardware-validated
  2026-11-11, on a unit whose rootfs slots still held that set's rootfs). It is
  a valid recovery only in that case: each restored UKI carries the set's root
  hash, so a slot updated by OTA since then fails verity, and the restored
  entries carry no counter, so a failing primary resets without end.
- **Matched recovery** (`--only recover`). Writing p69, `rootfsA` and `rootfsB`
  from one install set gives every slot a UKI and rootfs from the same build,
  whatever OTA did before. `/data` and `efiA`/`efiB` are not written. This is
  the recovery for a unit that may have taken an OTA (hardware-validated
  2026-11-11: a unit with both slots updated by OTA, one carrying a failing UKI,
  booted the set's build with `/data` intact). RAUC's slot status in `/data/rauc`
  is not written by this restore: each slot's installed-bundle record still
  describes its last RAUC install, until RAUC installs into that slot again.
  Marking a slot good, bad or active does not rewrite that record.
  `--only recover` refuses an install set built for the efi variant, whose slot
  UKIs are on `efiA`/`efiB`, which it does not write.
- **Recovery.** The vendor factory image restores the factory GPT and OS
  through the same EDL path (hardware-validated 2026-11-12 with
  `arduino-flasher-cli`, factory build 20260710-235). That restore rewrites both
  firmware banks, `dtb_a`/`dtb_b` and `persist`, and skips the unit-specific
  partitions. The allowlist restore below has not been run on hardware.
- **What gets restored afterwards is an explicit allowlist, not a blanket
  restore.**
  - **Normal case:** neither this installer nor the factory image moves or writes
    the other unit-specific partitions. Then **`persist` only** is restored from
    the per-unit backup.
  - **The condition behind that:** each other unit partition is first verified
    to be intact at its unchanged location (GPT name and LBA range, and content
    hash against the per-unit backup).
  - **Any partition that fails that check** is handled individually, as a
    reviewed exception.
- **`secdata` is never restored routinely.** `qdl` refuses to write it without
  `--allow-fusing`, and that flag is never part of a recovery procedure.
- **Proven only by a real restore.** Recovery counts as proven only after an
  observed restore on the unit. A read-only EDL session does not prove it.

### 5. Boot payload: one UKI per slot

**What a UKI contains.** Each slot's UKI is built by this repo and carries:
- the kernel;
- `.cmdline`: `root=/dev/dm-0`, the `dm-mod.create=` verity table with its root
  hash, and `rauc.slot=A|B`, the same construction as ADR-0008;
- `.dtb`: the board DTB built with the kernel;
- `.osrel`.

**No initramfs.** The built-in dm-init creates the mapping, as on the other
boards.
- **The family owns the UKI task.** oe-core's `uki.bbclass` is not used: it
  defaults `INITRAMFS_IMAGE` to `core-image-minimal-initramfs`, adds that image
  as a `do_image_complete` dependency, and always passes `--initrd` to `ukify`.
  Clearing `INITRAMFS_IMAGE` alone does not remove those paths.
- `edge-ab-uefi-uki.bbclass` runs `ukify` itself (`do_image_verity_uki`), once
  per slot, with the stub, kernel, board DTB, slot command line and the image's
  `os-release`, and no initrd.

**The bundle carries the coupled set.** A RAUC bundle carries a slot's
`ext4.verity` and that slot's UKI, so kernel, DTB, root hash and rootfs ship as
one coordinated set (ADR-0008).

**What systemd-stub does with these sections** ([systemd-stub(7)](https://www.freedesktop.org/software/systemd/man/latest/systemd-stub.html)):
- "If a DeviceTree is embedded in the .dtb section, it replaces an existing
  DeviceTree in the corresponding EFI configuration table. systemd-stub will ask
  the firmware via the EFI_DT_FIXUP_PROTOCOL for hardware specific fixups to the
  DeviceTree."
- With UEFI Secure Boot off, an EFI command line passed to the UKI overrides its
  `.cmdline`. The section is enforced only "If UEFI SecureBoot is enabled".

**Consequences for the loader and boot entries:**
- `loader.conf` sets `editor no` (custom variant; the efi variant has no loader).
- No boot entry passes load options to a UKI. The factory `Boot0000` carries
  none, the efi variant's `A`/`B` entries (§6) are created without any, and
  systemd-boot passes none to a Type #2 entry.
- That removes the casual override paths. It does not anchor anything (§2).

### 6. RAUC slot model and boot flow: `custom`

The `uefi-uki` family uses RAUC's `custom` backend over systemd-boot boot
counting. The `efi` variant below was built and run on the unit first; it is
recorded as the rejected alternative and is not carried in the build.

**Why `efi` was left.** On this firmware (`BOOT.MXF.1.0.c1-00460`):
- Any boot through `BootNext` faults in UEFI DXE before the OS loader runs,
  every power-on, until the unit is re-flashed over EDL (observed 2026-10-29).
  RAUC's `efi` backend sets `BootNext` on every activation.
- With `efi-use-bootnext=false` instead, a slot that hangs or panics has no
  automatic fallback: the firmware leaves `BootOrder` only on a load failure.
- `BootOrder` and the `Boot####` entries persist only through the OS-side
  re-seed of the file-backed store (Context).

**Common to both variants:**
- Slots `rootfs.0`/`rootfs.1` are `type=raw` on `rootfsA`/`rootfsB`, as today.
- The install marks the target bad before writing and activates it only after a
  complete install.
- A slot is marked good by `rauc-mark-good` (early, not health-gated), as on the
  other boards.
- A panicking kernel self-reboots (`CONFIG_PANIC_TIMEOUT=10`, platform-wide).
- `restart_on_corruption` turns a verity failure into a reboot.

#### Variant `efi` (RAUC `bootloader=efi`) — rejected

Boot entries:
- No systemd-boot. Each slot's UKI lives on its own VFAT slot (`efiA`/`efiB`,
  RAUC `type=vfat` slots `efi.0`/`efi.1`, installed by RAUC itself), at
  `\EFI\BOOT\BOOTAA64.EFI`.
- Two firmware boot entries point at those UKIs with no load options. Their
  labels are `A` and `B`, equal to the slots' `bootname`: RAUC finds a slot's
  entry by label, and marking a slot good fails with "No entry for bootname"
  when the entry is missing.

Per RAUC's reference:
- **Activate:** marking a slot primary "Sets the slot as `BootNext` by default.
  This will make the slot being booted upon next reboot only!"
- **Confirm:** marking it good "Prepends the slot to the `BootOrder` list".
- **Booted slot:** RAUC reads it from `rauc.slot=` on the kernel command line,
  which each slot's UKI carries.

**Who creates the entries: a first-boot unit in the image.**
- **Before `rauc-mark-good`.** It creates the `A` and `B` entries if they are
  absent. It is ordered before `rauc-mark-good`, so the first confirmation
  finds its entry.
- **`BootOrder` stays RAUC's.** The unit puts `A` first only while `BootOrder`
  names neither slot, a state that exists only before the first mark-good:
  RAUC removes a slot it marks bad, prepends one it marks good, and keeps the
  booted one.
- **Firmware entries Linux cannot list leave `BootOrder`.** `efibootmgr`
  refuses a `BootOrder` naming an entry it cannot list, and RAUC drops such
  entries whenever it rewrites `BootOrder`. The factory `BootOrder` (`0007`)
  therefore does not survive the first boot; whether the firmware restores
  or reorders it is criterion 4 below.
- **Unreadable entries are kept.** An `A` or `B` entry whose device path the
  unit cannot parse is left in place rather than recreated, so a
  firmware-normalised path cannot make it renumber the entries RAUC uses.
- **Idempotent.** An entry whose label and target already match is left as it
  is, so every boot can run it.
- **In the image, not in the installer.** A re-install and an OTA update both
  carry it, and it runs on the bench like any other unit.

**Bootstrap: the first boot comes from the ESP.**
- **Why a bootstrap.** The installer writes no EFI variables. It places slot A's
  UKI at the ESP's removable-media path (`\EFI\BOOT\BOOTAA64.EFI`) and at the
  factory `Boot0000` path (`\EFI\ubuntu\shimaa64.efi`), so the firmware's own
  entries boot it.
- **Same command line as slot A.** The copy carries `rauc.slot=A`, so RAUC sees
  slot A either way.
- **Kept.** The firmware loses `Boot####` variables across a reboot (Context),
  and the copy is the only boot path that does not depend on them. Deleting it
  after the first boot through entry `A`, as first decided, made a unit
  unbootable at the next power-on once its entries were lost (2026-10-28).
- **What keeping it costs.** OTA never updates the copy. Once slot A's rootfs
  is updated, a firmware fallback to the copy boots an old root hash over the
  new rootfs, and verity resets the board on every boot. A stale copy is
  recoverable by re-image; a unit with neither entries nor copy is too, but the
  copy also covers the case where slot A is unchanged.
- **When the firmware uses it.** With no `BootOrder`, the firmware boots the
  copy. With a `BootOrder` naming only lost entries, it took its removable-media
  path and stopped (2026-10-28, copy already deleted); whether that path reaches
  the copy on the ESP is not established.

Flow:
1. Install B; RAUC sets `BootNext` to entry `B`.
2. On reboot, the firmware boots B once.
3. If B reaches `rauc-mark-good`, B is prepended to `BootOrder` and becomes
   sticky.
4. If B panics, fails verity, or is reset before confirmation, the next boot
   follows `BootOrder` back to A.

**Rollback after one failed attempt.** Any reset during B's trial boot, a power
cut included, reverts to A, and the update has to be installed again. This is
RAUC's reference behaviour; on this firmware a consumed `BootNext` persists only
once Linux writes the store again (Context, bench run below). The
`uboot-fit` boards allow three attempts (`boot-attempts=3`).

#### Variant `custom` (RAUC `bootloader=custom` over systemd-boot boot counting)

**No EFI variable in the boot path.**
- systemd-boot is the ESP's removable-media loader (`\EFI\BOOT\BOOTAA64.EFI`),
  also at the factory `Boot0000` path (`\EFI\ubuntu\shimaa64.efi`). The install
  set's ESP carries the unit's empty variable store, so the firmware has no
  `BootOrder` and boots the removable-media path.
- No EFI variable is written at runtime: no boot-entry unit, no `efibootmgr`,
  and the backend renames files only. systemd-boot sets its own variables in
  boot services (`LoaderSystemToken` among them), which this firmware does not
  persist, and none of them selects a slot. The store file stays as installed,
  so the variable-persistence defects (Context) do not reach slot selection.
- Both slot UKIs are Type #2 entries on the ESP. systemd-boot scans only its own
  partition and one XBOOTLDR partition, so `efiA`/`efiB` hold empty file
  systems in this variant: no firmware entry can reach a stale UKI there.

**Entries.** `\EFI\Linux\edge-<gen>-<slot>[+<left>[-<done>]].efi`, slot `a` or
`b`, `gen` a positive integer. A fresh install writes `edge-2-a.efi` and
`edge-1-b.efi`: A primary, both confirmed. `loader.conf`: `default edge-*`,
`timeout 0`, `editor no`, `auto-entries no`.

**Activation: a constant `IMAGE_VERSION`.** systemd-boot 259.5 orders Type #2
entries by tries left (none left sorts last), then sort key (`.osrel` `IMAGE_ID`,
else `ID`), then version (the first present of `IMAGE_VERSION`, `VERSION`,
`VERSION_ID`, `BUILD_ID`), newest first, then entry id (file name without the
counter), highest `strverscmp` first. Each UKI's `.osrel` is the rootfs
`os-release` plus `IMAGE_VERSION=0`; the build refuses a rootfs `os-release` that
sets `IMAGE_ID` or `IMAGE_VERSION`. With sort key and version equal on every
UKI, the generation in the file name is the order, and a higher generation makes
a slot primary whatever its release.
- Considered: removing `ID` from `.osrel` also leaves name order (host result
  below). Rejected: a UKI built without the change outsorts every other entry,
  while a missing constant `IMAGE_VERSION` only sorts by release.
- Migration from `efi` is a re-image: the ordering of UKIs without the constant
  differs, and the slot UKIs move to the ESP.

**Backend** (`/usr/libexec/edge-sdboot-backend`, `edge-sdboot-backend` recipe):

| RAUC call | Action |
|---|---|
| `get-primary` | first slot in systemd-boot's order: tries left, then generation |
| `set-primary <slot>` | rename to `edge-<highest gen + 1>-<slot>+3.efi` |
| `get-state <slot>` | `bad` when no tries are left, else `good` |
| `set-state <slot> good` | drop the counter |
| `set-state <slot> bad` | set `+0` (an exhausted entry keeps its name) |
| `get-current` | slot of `LoaderEntrySelected`; RAUC reads `rauc.slot=` first |

Each call takes a lock, refuses an unrecognised `edge-*` name or two entries for
one slot, and flushes the directory after a rename. The bundle's rootfs
post-install hook replaces the target slot's UKI under its current name
(`install-uki`), between RAUC's `set-state bad` and `set-primary`.
`systemd-bless-boot` is masked, so RAUC alone confirms a slot, and
`systemd-boot-update` is preset off, so a rootfs carrying a newer systemd-boot
does not rewrite the ESP's single loader copy (§9).

Flow:
1. Install B: RAUC marks B bad (`+0`), writes rootfs B, the hook installs B's
   UKI, and RAUC activates B (`edge-<n>-b+3.efi`).
2. systemd-boot boots B, renaming it to `+2-1` first.
3. `rauc-mark-good` drops B's counter; with `prevent-late-fallback`, A becomes
   `+0`.
4. If B resets three times before confirmation, it has no tries left, sorts
   last, and A boots. Rollback follows three failed attempts, as
   `boot-attempts=3` on the `uboot-fit` boards.

**What the exhaustion fallback relies on** (systemd v259.5, `src/boot/boot.c`):
- Entries with no tries left sort last (`boot_entry_compare`).
- The `default` pattern is matched without boot assessment, so `default edge-*`
  returns the first sorted entry. A `default` naming one slot would keep booting
  it after it went bad.
- `LoaderEntryDefault` and `LoaderEntryOneShot` take precedence over
  `loader.conf`. Nothing in the image sets them.

**Evidence.**
- The backend's `get-primary` agrees with systemd v259.5's own
  `boot_entry_compare` and `bootspec_pick_name_version_sort_key`, compiled on the
  host, on 8280 of 8280 slot-name layouts (generations 1 to 999999999, counters
  `+0` to `+10-5`, release versions differing between the slots).
- Hardware-validated 2026-11-11, image `edge-image-dev-ventuno-q.rootfs-20261111131317`:
  - With the installed empty store, the firmware boots `\EFI\BOOT\BOOTAA64.EFI`
    (systemd-boot 259.5), which boots `edge-2-a.efi`. No `Boot####`, `BootOrder`
    or `BootNext` variable exists, and the store file is unchanged after clean
    reboots and a power cut.
  - A slot UKI whose root hash fails verity resets three times, its counter
    going `+3` to `+0-3` with a power cut during the second attempt, and the
    other slot then boots unattended.
  - A generation bump activates a slot whose `.osrel` carries the older release;
    systemd-boot decrements the counter before the boot (`LoaderBootCountPath`),
    and `rauc-mark-good` confirms the slot and sets the other to `+0`.

#### Bench run that settles the backend

The hardware-dependent assumptions of §6 and §7 are checked in one bench run on
the unit, before the board's first OTA test.

Criteria 1 and 2 depend on variable persistence (Context): a `BootOrder` written
in one boot is lost at the next boot that writes any other variable, and a
consumed `BootNext` stays in the stored file. As the firmware behaves on
2026-10-28, `efi` cannot meet them without an OS-side measure that rewrites the
whole store on each boot, and rollback from a slot that fails before userspace
needs the firmware to persist `BootNext` consumption.

`efi` stays only if all four of these hold:
1. A `BootNext` written from Linux is honoured on the next boot and consumed,
   with `BootCurrent` matching.
2. A `BootOrder` written from Linux survives several reboots and a power cycle.
3. The firmware boots a boot entry whose UKI is on a non-ESP VFAT partition.
4. The firmware does not create or reorder boot entries in a way that overrides
   a `BootOrder` written from Linux. The factory unit already boots through
   firmware-created entries Linux cannot see (Context), so this is the
   criterion most at risk. RAUC must also parse a `BootOrder` that names such
   entries.

`custom` additionally requires that the firmware boots
`\EFI\BOOT\BOOTAA64.EFI` when no valid boot entry remains, that systemd-boot's
renames persist across a reboot and a power cut, that an exhausted entry is
passed over after a real failure, that a generation bump activates an older
release, and that a systemd-boot boot leaves the variable store unchanged. All
of these hold on the unit (Evidence above).

The same run checks:
- the DT fixups (§7), first, since the first boot depends on them;
- that the board boots from the ESP copy when `BootOrder` names only entries
  the firmware no longer has.

**Outcomes.** Criterion 1 fails on this firmware (the `BootNext` fault above),
so the board uses `custom`.

#### What rollback does not cover

The limits are the same as on the other boards:
- A slot that hangs without resetting is not caught until a watchdog is armed on
  this board.
- A slot whose workload fails after confirmation is not caught.

### 7. DTB ownership

**Normal path.** The UKI's `.dtb` is authoritative and A/B-coupled with its
kernel. The OS does not write `dtb_a`/`dtb_b` at all.

**Fallback.** It applies only if the bench shows the Qualcomm UEFI does not
provide the DT fixups the kernel needs when systemd-stub replaces the DTB.
- **Its payload rule differs:** the fallback UKI carries **no** `.dtb` (nor any
  other replacement DT section, such as `.dtbauto`), so `UKI_DEVICETREE` is
  empty. A UKI that still embeds a DTB would replace the firmware's tree and
  defeat the fallback.
- **Checks:** the built UKI's PE sections, and the device tree the running kernel
  actually received.
- The installer writes the **same** kernel-compatible DTB to **both** banks.
- A firmware bank switch then never changes the DTB.
- A DTB change is then a cross-slot change, like a FIT-key change on the other
  boards: it must remain valid for the kernel in the other slot, and it ships
  only with an update that keeps both slots compatible.
- Unlike the factory OS, the installer never writes one bank alone.
- **Cross-slot compatibility does not make rewriting both banks power-loss safe.**
  That write stays an attended installer operation, outside unattended OTA,
  until its sequencing is designed and tested.

### 8. dm-verity and kernel lockdown under "no secure boot"

**dm-verity** is built and enabled as on the other boards, with the label from
§2:
- It detects rootfs corruption and refuses modified blocks at runtime.
- It does not authenticate the rootfs. Anyone who can write the ESP or `efiA`/
  `efiB`, or supply an EFI command line, can boot a different root hash. That
  includes any root process, through `efivarfs`: lockdown does not stop EFI
  variable writes.

**Kernel lockdown** follows the platform: compiled in, mode `NONE`, inactive.
- **When the platform activates it,** this board needs Kconfig
  (`CONFIG_LOCK_DOWN_KERNEL_FORCE_*`), because the UKI command line is
  overridable here.
- **What it would protect:** the running kernel against root.
- **What it would not protect:** replacing the kernel on the next boot.

### 9. Bootchain update (ADR-0014 stance)

**v1 has no bootchain-update backend for this board.** `BOOTLOADER_UPDATE=1` is
a no-op with the Makefile's existing warning, and Qualcomm firmware is outside
OTA scope:
- **No safe update path.** Qualcomm's documented firmware update is a UEFI
  capsule. Without a provisioned RPMB, which decision 1 excludes, a capsule can
  still be applied, but with no trial boot and no rollback (see Context). A
  firmware write without rollback has no fallback.
- **The firmware is not ours.** It is not built by this repo, and is
  redistributable only in binary form under the vendor licence.
- **Re-imaging is the only way.** A firmware change on this board is a
  re-image through EDL, attended.

systemd-boot (custom variant) is installed at provisioning and is not changed by
OTA in v1, because the ESP holds a single copy. The efi variant has no loader to
update; its ESP holds only the bootstrap UKI, which is kept as a fallback (§6)
and is never a slot payload.

### 10. Board scope fixed by the constraints

**BSP and binaries:**
- Machine `ventuno-q` from `meta-qcom-arduino` `wrynose`; Linux at EL1 under
  Gunyah (no `kvm`).
- Qualcomm binaries are fetched at build time under their licence flags. No
  image or bundle containing them is published.

**STM32H5.** It is used through `cdc_acm` and `gs_usb`; its firmware is not
built or updated.

**`packagegroup-ventuno-q`.** It inherits `packagegroup` without setting
`PACKAGE_ARCH`, and resolves to `all` while recommending machine-architecture
kernel-module packages. It is used as is.
- **Why that is safe here.** An `allarch` package's sstate signature does not
  carry `MACHINE`, and `SSTATE_DIR` is shared between boards. Only the
  `ventuno-q` machine pulls it in, and it is the only `meta-qcom-arduino`
  machine this repo composes, so no other machine builds or restores it.
- **When it is not.** A second `meta-qcom-arduino` machine in this repo makes
  the board use its own packagegroup, with `PACKAGE_ARCH = "${MACHINE_ARCH}"`
  set before `inherit packagegroup`.
- **Why a bbappend cannot repair it.** `packagegroup.bbclass` snapshots
  `PACKAGE_ARCH_EXPANDED := "${PACKAGE_ARCH}"` when the recipe's `inherit` line
  is parsed, then adds `allarch` with `inherit_defer` based on that snapshot. A
  bbappend that sets only `PACKAGE_ARCH` does not change the decision.

## Integration rules

- **Vendor layers are not edited.** Each `meta-qcom` composition friction is
  resolved in the board's kas and include files:
  - `efi` in `DISTRO_FEATURES`;
  - the hard `MACHINE_FEATURES =` in `meta-qcom`'s `qcom-common.inc`, which
    `ventuno-q.conf` extends with `+= "efi pci tpm2"`;
  - the machine's `IMAGE_FSTYPES += ext4 qcomflash`;
  - the injected `image_types_qcom` and `linux-qcom-dtbbin`;
  - the `meta-lts-mixins` dependency;
  - `INHERIT += qli-mirrors` applying to every fetch.
- **Shared edits leave the other boards' task signatures unchanged.** The
  family dispatch, the `EDGE_BOOT_ANCHOR` gate and the new class paths were
  checked with `bitbake -S printdiff` on rzv2l and raspberrypi5.
- **The platform kernel policy applies.** The `linux-qcom` bbappend requires
  `edge-kernel-policy.inc`, so the platform symbol assertions and the
  module-signing key apply (ADR-0011 §4).

## ADR-0011 revisit trigger

ADR-0011 lists "a third board joins whose vendor BSP fits neither pattern" as a
revisit trigger. It has fired, and this ADR does not cover it:
- **The kernel** is `linux-qcom` 6.18, a Qualcomm vendor tree. It is neither
  CIP SLTS nor a kernel.org longterm pin.
- **Neither of ADR-0011's patterns can carry this board today.**
  - The board's device tree first appears in mainline in v7.1.
  - It is not in the 6.18 longterm line.
- **A separate ADR records it.** The kernel base is a different decision from
  the boot chain, with its own maintenance horizon and CVE surface. It is
  recorded in [ADR-0011](0011-per-board-kernel-base.md) (decision 6).

## Consequences

**Platform:**
- The platform carries two boot-chain families. Shared classes branch on
  `EDGE_BOOT_CHAIN`, and the trust-anchor level becomes an explicit, recorded
  board fact on all three boards.
- RAUC's `system.conf` takes the family's `bootloader=` and the slot sections
  the family needs.

**Install, recovery and firmware:**
- First install and recovery are attended EDL operations. There is no
  self-hosted installer in v1.
- Firmware CVEs on this board are fixed only by an attended re-image, until a
  decision on RPMB enables capsule trial boot.

**What stays open:**
- Reversibility is kept. Fused secure boot, UEFI Secure Boot and capsule trial
  boot all remain available to a later decision, because nothing here provisions
  RPMB or writes fuses.
- A `prod` image on this board needs an explicit unanchored-verity waiver, which
  is a visible, reviewable line.

## Alternatives considered

- **`u-boot-qcom` replacing `uefi.elf`, keeping `uboot-fit`.** Qualcomm's
  [U-Boot page](https://dragonwingdocs.qualcomm.com/System/Boot/u-boot-on-qualcomm-linux.md)
  lists IQ-8275 (the same SoC) with `qcom_qcs8300_defconfig` and storage "UFS".
  It builds the binary "as `uefi.elf`" and flashes it with `fastboot flash
  uefi_a u-boot.mbn`, after test-signing with `qtestsign`. Rejected for v1:
  - It writes `uefi_a`/`uefi_b`, which decisions 2 and 4 exclude.
  - There is no `ventuno-q` configuration.
  - It would raise this board from `none` to `loader-key` (§2), the level the
    other boards have. That gain does not outweigh rewriting the firmware banks
    on a unit that must stay reversible.
- **`meta-qcom` `qcomflash` full flash with its partition table.** Rejected by
  decision 4:
  - It rewrites every firmware partition.
  - Its table differs from the factory GPT from p23, which moves the
    unit-specific partitions.
- **Qualcomm's documented OSTree with boot counting on a single rootfs.**
  Rejected: the platform's update unit is a signed RAUC bundle with an A/B
  verity rootfs (ADR-0005, ADR-0008). The `custom` variant keeps the same
  boot-counting mechanism under RAUC.
- **Provision RPMB and enable UEFI Secure Boot now.** Excluded by decision 1.
  Recorded here because it is the only path that moves this board to a signed
  UKI, and it is one-time.
