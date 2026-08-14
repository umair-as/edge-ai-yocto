# ADR-0008: Runtime rootfs dm-verity

- Status: Accepted
- Date: 2026-08-12

## Context

RAUC's `verity` bundle format authenticates the install artifact but does not
verify rootfs reads after installation. Runtime verification also has to bind
the root hash to authenticated boot policy without changing the four-partition
eSD MBR layout.

## Decision

Every A/B image produces a self-contained `ext4.verity` artifact with its
Merkle tree appended after the ext4 data. Both rootfs partitions initially
receive that artifact. RAUC installs it through `type=raw`; `type=verity` is
not a RAUC slot type.

The image task produces `fitImage-A` and `fitImage-B`. Each configuration
signature covers the kernel and a slot-specific DTB whose `/chosen/bootargs`
contains the root hash, table geometry, physical partition, and
`root=/dev/dm-0`. The built-in device-mapper initializer creates the read-only
mapping without an initramfs. Hash failure uses `restart_on_corruption`, so the
existing RAUC boot-attempt counter can select the other slot.

The shared `/boot` filesystem remains, but OTA replaces only the inactive
slot's FIT before marking that slot verity-ready in the redundant U-Boot
environment. Existing deployments retain the legacy `fitImage` path for any
slot not yet updated. The initial transition requires flashing a complete
verity image: an older running system declares `type=ext4` and would select an
ext4 update handler instead of the required raw handler. After the baseline
flash, normal RAUC updates use `type=raw` and the legacy path is unnecessary.

## Consequences

- Local base, dev, and prod roots are read-only. NFS netboot remains the
  writable development workflow; `/data` supplies persistent writable state.
- Kernel, DTB, root hash, and rootfs must be released as one coordinated RAUC
  bundle.
- A newly flashed image uses U-Boot's compiled default to boot `fitImage-A`;
  userspace then seeds the redundant managed environment for later boots.
- The root hash is protected by FIT verification, but interactive U-Boot shell
  access can still select alternate commands. This ADR does not claim a
  hardware-rooted or console-resistant chain.

## References

- [RAUC FAQ: dm-verity-protected partitions](https://rauc.readthedocs.io/en/latest/faq.html)
- [Linux dm-init](https://docs.kernel.org/admin-guide/device-mapper/dm-init.html)
- [Linux dm-verity](https://docs.kernel.org/admin-guide/device-mapper/verity.html)
