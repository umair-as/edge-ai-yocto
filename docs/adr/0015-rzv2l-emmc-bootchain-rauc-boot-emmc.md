# ADR-0015: RZ/V2L eMMC bootchain updates through a RAUC boot-emmc slot

- Status: Accepted
- Date: 2026-10-12
- Amends: [ADR-0014](0014-bootchain-update-mechanism.md) (resolves its open question on
  RAUC-integrated delivery for the RZ/V2L eMMC target; delivery stays attended)
- Relates: [ADR-0006](0006-emmc-gpt-boot-target.md) (eMMC layout),
  [ADR-0005](0005-image-class-ota-backend.md) (RAUC rootfs OTA)

## Context

On an eMMC-booted RZ/V2L the mask ROM loads BL2 from the hardware boot partition that
EXT_CSD[179] `BOOT_PARTITION_ENABLE` selects, and BL2 loads the FIP from the same
partition. The eMMC has two boot partitions (`boot0`, `boot1`, 31.5 MiB each on the
SMARC module). The ROM never tries the other partition: there is no automatic
fallback. `rzv2l-bootloader-update --mode emmc` writes `boot0` in place, which leaves
no intact copy while it writes.

Bootchain updates must stay separate from the rootfs bundles: rootfs bundles are
frequent and can be installed unattended; a bootchain update (a TF-A, OP-TEE or U-Boot
fix) is rare and must be operator-attended.

RAUC 1.15.2 (the meta-rauc version in the build) has a `boot-emmc` slot type: it reads
EXT_CSD[179], clears and writes the inactive boot partition, runs the image's slot
hooks, and then switches EXT_CSD to it with one register write, keeping `BOOT_ACK`.

## Decision

On the RZ/V2L eMMC boot target (`EDGE_BOOT_TARGET=emmc`), bootchain updates go through
a RAUC `boot-emmc` slot, `bootloader.0` on `/dev/mmcblk0`, with BL2 and FIP delivered
together in a separate, signed, **bootloader-only** bundle (`rzv2l-bootchain-bundle`).
The slot exists only on that boot target; the eSD and QSPI targets and every other
board are unchanged.

- **One image per boot partition.** The bundle carries one composed image written
  from byte 0: zero to 0x1FF, `bl2_bp_mmc` at 0x200, the FIP at 0x20000. BL2 and FIP
  always move as a pair.
- **Operator authorization.** A system pre-install handler refuses any bundle that
  carries the `bootloader` image unless `rzv2l-bootchain-authorize` has recorded an
  authorization for that bundle's image digest and build id, for the current boot,
  unexpired; the handler consumes it on the first attempt, whatever the outcome. The
  printed install command also pins the manifest hash. A bundle that carries the
  bootloader together with any other image is refused.
- **Guards before any write** (the pre-install handler): booted from eMMC
  (`/chosen/edge,boot-source`), `boot0` or `boot1` enabled, `BOOT_ACK` off, 8-bit boot
  bus, the PMIC variant, the TF-A pin's FIP offset, the image layout and BL2 header
  (size word = body rounded up to 4 bytes), and the FIT anchor: the candidate FIP's
  U-Boot DTB must hold, as `required="conf"`, the same RSA key as the current anchor
  for each installed slot FIT's signer. No name-only fallback.
- **Read-back before activation.** The slot post-install hook reads the written
  partition back and compares it with the image digest; RAUC switches EXT_CSD only
  after it succeeds. The handler also refuses a bundle without the pre- and
  post-install hooks, with an `install` hook, bundle hooks or a custom handler, or
  whose hook file differs from the reference copy on the rootfs.
- **RAUC fix.** RAUC 1.15.2 passes the boot-emmc slot hooks a temporary slot without
  name or class and refuses to run them (rauc issue #1893). The fix is upstream
  (a75bbb2b, PR #1901) but in no RAUC release yet; the layer carries it as a verbatim
  backport for every machine until the pinned meta-rauc ships a release with it.
- **Build-time checks.** The bundle recipe composes and checks the image (BL2 header,
  FIP ToC, overlap, TF-A pin and layout table, size) and runs the FIT trust gate on the
  anchor in the bundle's own FIP.

`rzv2l-bootloader-update` stays as the lab and recovery tool for QSPI, eSD and a
`boot0`-enabled eMMC, and for provisioning a current bootchain into `boot0`. It refuses
to write while EXT_CSD enables `boot1`.

Hardware-validated 2026-10-12 on the RZ/V2L SMARC EVK (PMIC): install from `boot0`
into `boot1`, read-back, switch and boot, then back into `boot0`, switch and boot.

## Consequences

- An interrupted or failed write leaves the active partition and EXT_CSD unchanged; the
  board keeps booting the previous bootchain.
- A bootchain that fails before U-Boot, once selected, needs external recovery:
  `mmc bootpart enable` from a running Linux, `mmc partconf` from a QSPI-booted U-Boot,
  or the SCIF Flash Writer. RAUC has no trial boot for this slot, and the ROM has no
  fallback, so this is atomic selection with manual recovery, not automatic rollback.
- Installing a bundle rewrites the inactive partition. The previous firmware stays in
  the other partition only until the next install; returning to an older bootchain
  means installing its bundle.
- The rootfs must carry the patched RAUC and the guard package before a bootchain
  bundle can install; stock RAUC 1.15.2 refuses the hooked install before writing.
- A board whose `boot0` holds a bootchain without `/chosen/edge,boot-source` is
  refused; it is first provisioned with a current bootchain through
  `rzv2l-bootloader-update --mode emmc`.
- The authorization lives in `/run`: a reboot clears it.

## Alternatives considered

- **Extend `rzv2l-bootloader-update` to alternate `boot0`/`boot1`.** Rejected in favour
  of RAUC: signed delivery, the inactive-partition write and the EXT_CSD switch already
  exist in RAUC, and the guards run as its handler and hooks.
- **Ship the bootloader inside the rootfs bundle.** Rejected: RAUC switches the boot
  partition at install time and the rootfs slot at reboot, coupling a rare attended
  update to the frequent unattended one.
- **FIP A/B selected by a modified BL2, or Arm PSA FWU metadata.** Rejected: BL2
  stays single-copy, both need TF-A changes, and the eMMC boot partitions already give
  two complete copies of BL2 and FIP.
- **A separate `system.conf` for bootchain installs.** Rejected: the running RAUC
  service uses the system configuration; a pre-install handler gates the shared one.
