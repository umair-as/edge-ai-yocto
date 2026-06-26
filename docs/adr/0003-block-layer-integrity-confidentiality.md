# ADR-0003: Block-layer integrity, confidentiality, and rootfs hardening

- Status: Accepted
- Date: 2026-06-16

## Context

A long-lived edge-Linux device makes four storage-layer security claims
that are routinely conflated:

1. **Boot-chain authenticity** — the kernel + dtb + initramfs that ran are
   the ones the platform signed.
2. **Bundle integrity at install** — the artifact about to be committed
   wasn't mutated or truncated in transit.
3. **Runtime rootfs integrity** — the rootfs being read *now* is the one
   installed; nothing modified the block device after boot.
4. **Confidentiality of writable data** — logs, secrets, customer data,
   model intermediates are unreadable to an attacker with disk access.

The device-mapper subsystem (`dm-verity`, `dm-crypt`, `dm-integrity`) plus
`veritysetup`/`cryptsetup` cover the storage parts of (2)–(4) — *if each
capability is wired for the role it actually plays*. The classic failure is
conflating them: e.g. assuming `bundle-formats=verity` in RAUC implies a
verity-protected runtime rootfs. A second axis the model makes explicit:
**kernel capability** vs **userspace tooling** vs **boot/install wiring** —
a capability the kernel *can* do is not one the device *does* until all
three legs exist.

This ADR is platform doctrine: it applies to every machine in the
catalogue and is the reference for adding storage-security wiring.

## Decision

Storage-layer security is a **six-layer stack with distinct,
non-overlapping roles**. Each layer has a fixed purpose, kernel-side
enabler, and wiring path; fragments are named after the layer they wire
(`dm-crypt.cfg` = L4, `rauc-verity.cfg` = L2, …).

| Layer | Role | Kernel side | Userspace + wiring side |
|-------|------|-------------|-------------------------|
| **L0** Hardware crypto + entropy | Throughput and entropy quality for everything above | `CONFIG_CRYPTO_*ARM64_CE*` (instruction acceleration), `CONFIG_HW_RANDOM_*` (HWRNG drivers — OP-TEE, TPM, vendor SoC), `CONFIG_RANDOM_TRUST_BOOTLOADER` | Autodetected; no configuration. May need `rng-tools` to feed `/dev/urandom` faster early-boot. |
| **L1** Boot-chain authenticity | "The kernel that runs is the one we signed" | FIT image signing (verified by U-Boot / TF-A) | Outside dm-* scope. Covered by FIT signing + bootloader policy. |
| **L2** Bundle integrity at install | "What we just received and are about to commit isn't tampered" | `CONFIG_DM_VERITY` (+`BLK_DEV_DM`, `DM_BUFIO`) | RAUC `bundle-formats=verity` in `system.conf`. RAUC verifies the verity-protected bundle artifact *before installing it into a slot*. |
| **L3** Runtime rootfs verity | "The rootfs blocks I'm reading *right now* haven't been mutated since install" | same as L2 (verity itself is one feature; this layer reuses it) | Distinct wiring: rootfs slot type changed from `ext4` to verity-format, signed roothash transported via FIT `bootargs` or U-Boot env, `systemd-veritysetup` or kernel `dm-mod.create` cmdline assembles the verity device at boot. **Not provided by L2.** |
| **L4** Block-device encryption | Confidentiality (+ optional integrity) of writable data partitions | `CONFIG_DM_CRYPT`, `CONFIG_DM_INTEGRITY`, `CONFIG_CRYPTO_XTS`, `CONFIG_CRYPTO_ESSIV`, `CONFIG_CRYPTO_USER_API_{SKCIPHER,HASH,AEAD}` (cryptsetup needs the AF_ALG sockets even when ciphers are in-kernel) | LUKS2 `cryptsetup luksFormat` of the writable partition, `/etc/crypttab` entry that systemd-cryptsetup-generator instantiates, mount via `/etc/fstab`. Requires an L5 key source. |
| **L5** Sealed key store | "The key that unlocks L4 is bound to *this* device and *this* boot state" | `CONFIG_TCG_TPM2_*` (if TPM present), or OP-TEE driver (`CONFIG_TEE`, `CONFIG_OPTEE`) | TPM2 PCR-sealed blob via `clevis`/`systemd-cryptenroll`, or OP-TEE TA that wraps/unwraps a key bound to chip-fused material. **Devices without either lose the unattended-boot story for L4** — only passphrase or boot-token unlock remains. |

Each layer is independently wireable: a platform may ship L0+L1+L2
(install-time integrity) without L3 (runtime rootfs verity) or L4 (data
encryption). The matrix specifies what each layer claims, does not claim,
and requires.

## Rationale

- **Layer separation prevents silent regressions.** Treating `dm-verity`
  as one feature ("verity is on") rather than two deployments (L2 bundle,
  L3 runtime rootfs) is the most common way a device *appears*
  verity-protected but isn't.
- **Kernel-ready ≠ device-using.** `CONFIG_DM_CRYPT=y` does not produce an
  encrypted partition. Separate "kernel side" and "wiring side" columns
  make a half-closed layer auditable.
- **`CONFIG_CRYPTO_USER_API_*` is the gotcha.** `cryptsetup` needs the
  AF_ALG sockets (`algif_skcipher/hash/aead`) even when ciphers are
  in-kernel; a kernel with `DM_CRYPT=y` + `CRYPTO_XTS=y` but no
  `CRYPTO_USER_API_SKCIPHER` fails with "Required kernel crypto interface
  not available" and no other hint. Not implied by `DM_CRYPT=y`, silently
  absent from many vendor defconfigs — verify on every kernel base; it
  belongs in L4.
- **`bundle-formats=verity` is L2, not L3.** It protects the bundle
  artifact during install; the running slot is whatever the slot type says
  (`type=ext4` = plain ext4, no runtime integrity).
- **Sealed key store (L5) is a layer, not a footnote.** L4 without L5 is an
  encrypted partition you can't unlock unattended — a non-feature for an
  embedded device. Making "have we wired L5?" explicit forces every L4
  deployment to answer it.
- **Acceleration is independent of correctness.** L0 (ARMv8 CE, HWRNG) is
  throughput/entropy, not a precondition for L2–L4 — missing L0 just runs
  slow.

## Consequences

- **Doctrinal:** every storage-security fragment cites the layer it serves;
  one fragment never spans layers, one layer never splits across fragments.
- **Wiring debt is visible.** A device shipping L2+L4 but no L3/L5 states it
  plainly — "bundle integrity, no runtime rootfs integrity, encrypted data
  with unsealed key." The matrix is the audit form.
- **ADR-to-recipe traceability.** "Is this device verity-protected at
  runtime?" is answered by checking L3's wiring column against the actual
  `system.conf` slot types and FIT `bootargs` — no code inspection or
  device probe.
- **Scope-bounding.** L3 and L5 wiring are separately scoped (below); the
  next ADR amends one layer rather than re-litigating the model.

## Follow-on work

- **Runtime rootfs verity (L3)** — ADR-worthy in its own right; four
  interacting changes: (1) a verity-formatted rootfs per slot at image
  build; (2) a verity-aware RAUC slot type; (3) signed roothash transport —
  cleanest is embedding it in the FIT `bootargs` so the FIT signature
  attests it; (4) verity device assembly at boot (`dm-mod.create=` cmdline
  or `systemd-veritysetup`). A follow-on ADR records the choices; (1) and
  (3) interact with the FIT-signing model.
- **Sealed key source (L5)** — TPM2 boards: `kas/tpm.yml` brings
  `meta-secure-core` / `meta-encrypted-storage`; productionising means
  picking a sealing tool (`clevis-tpm2` / `systemd-cryptenroll`), wiring
  `/etc/crypttab`, and recording the PCR set. TPM-less SoC+eMMC boards need
  an OP-TEE TA wrapping a HUK-derived key — TA development, signing-key
  custody, and the userspace helper are separate scope.

## Revisit triggers

- A new device-mapper target with platform-relevant semantics lands
  upstream and isn't covered by L0–L5 (e.g. block-layer authenticated
  encryption that obsoletes the L3/L4 split).
- The FIT signing model is replaced or augmented (UEFI Secure Boot for a
  board class, composefs instead of dm-verity) — L3 transport assumptions
  change.
- A platform-wide key-management decision (HSM-backed unwrap,
  attestation-driven release) subsumes the per-board L5 approach.
- A kernel base bump (per ADR-0001) flips the default-y/m disposition of an
  L0–L4 symbol so a fragment is no longer needed — the matrix narrows, the
  model stays.

## References

- [dm-verity — kernel device-mapper docs](https://docs.kernel.org/admin-guide/device-mapper/verity.html)
- [cryptsetup / LUKS](https://gitlab.com/cryptsetup/cryptsetup) — `cryptsetup`/`veritysetup` userspace; the AF_ALG (`CRYPTO_USER_API_*`) dependency lives here.
