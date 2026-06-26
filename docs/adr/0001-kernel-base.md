# ADR-0001: Kernel base — CIP 6.12 SLTS (via linux-renesas / rz_linux-cip)

- Status: Accepted
- Date: 2026-06-11

## Context

edge-ai-yocto is a Yocto-based platform for long-lived, secure
edge-AI devices. The kernel-base choice fixes three things at once:
the maintenance horizon of every shipped device, the security-update
cadence the platform can promise, and the alignment with where vendor
BSP work for the target SoC family (RZ/V2L initially) actually lives.

Relevant axes:

- **Maintenance horizon.** Mainline Linux LTS is supported for
  ~2 years. Industrial Super-LTS (SLTS) streams extend that to
  ~10 years.
- **Security posture.** A platform positioned as a base for secure,
  long-lived products inherits regulatory expectations such as
  IEC 62443 (industrial automation security) and the EU Cyber
  Resilience Act (CRA). Both assume sustained security maintenance
  across the device's service life — not just at launch.
- **Vendor BSP alignment.** Board-support patches for the chosen SoC
  family land against specific kernel versions; the kernel base
  should match where that work actually lives, not impose a
  permanent rebase tax.

## Decision

The kernel base is **linux-cip 6.12** — the Civil Infrastructure
Platform Super-Long-Term-Support (SLTS) 6.12 series.

The build recipe is **`linux-renesas`**, which fetches Renesas's
`rz_linux-cip` tree (`github.com/renesas-rz/rz_linux-cip.git`,
branch `rz-6.12-cip7`). `rz_linux-cip` is the CIP SLTS source with
RZ hardware enablement layered on top, maintained by Renesas in
lockstep with CIP backports — the same CIP base, not a divergent
vendor kernel. The recipe name `linux-renesas` is the `meta-renesas`
convention for this provider; it does not imply a departure from CIP.

Concrete configuration:

- **Provider**: `linux-renesas` (machine-selected via `meta-renesas/meta-rz-bsp`)
- **Version pin**: `PREFERRED_VERSION_linux-renesas = "6.12%"` in `kas/kernel.yml`
- **Source branch**: `rz-6.12-cip7` from `github.com/renesas-rz/rz_linux-cip.git`
- **Bbappend**: `meta-edge-bsp/recipes-kernel/linux/linux-renesas_6.12.bbappend`

## Rationale

1. **SLTS maintenance horizon (~10 years).** CIP SLTS branches are
   maintained for roughly a decade, against ~2 years for mainline
   LTS. A long-lived edge device must remain patchable through its
   field deployment without a forced kernel rebase mid-life.

2. **6.12 is the current CIP SLTS frontier.** The CIP SLTS series to
   date are 4.4, 4.19, 5.10, 6.1, and **6.12**. 6.12 is the newest
   selection, placing this platform on the active frontier. When CIP
   designates a post-6.12 SLTS series, that becomes the natural
   upgrade target.

3. **Industrial-security alignment.** CIP's stated focus is
   industrial-grade Linux with IEC 62443 alignment — directly
   relevant to the regulatory posture this platform targets
   (secure-product lifecycle, vulnerability-handling, sustained
   update availability — the same obligations the CRA imposes on
   products with digital elements).

4. **Vendor BSP cadence.** The RZ/V2L vendor BSP tracks the CIP
   series: `rz_linux-cip` is a CIP-based fork that Renesas advances
   in step with CIP backports. Choosing CIP keeps this platform
   aligned with where the vendor actually does board-support work,
   and using `meta-renesas`'s `linux-renesas` recipe is the direct
   realisation of that alignment — the same CIP intent, with board
   enablement included.

## Consequences

- **Trade-off accepted:** older kernel version than current mainline
  LTS, in exchange for the ~10-year maintenance horizon and the
  industrial-security alignment. The platform deliberately does not
  track bleeding-edge kernel features.

- **Upgrade path:** when CIP designates a post-6.12 SLTS series, a
  follow-on ADR records the move and the driver / fragment
  compatibility audit it requires. Until then this is the base.

- **Out-of-tree driver portability.** Drivers targeting older vendor
  kernels must be forward-ported to 6.12 before they can land. The
  DRP-AI accelerator driver — originally written against
  `rz_linux-cip 6.1` — has been forward-ported to this base and is
  hardware-validated. The port involved five API-drift fixes and a
  two-line `EXPORT_SYMBOL_GPL` patch for the cache-maintenance
  helpers the out-of-tree module calls; no changes to the accelerator
  logic were needed. See `docs/drp-ai/README.md` for the full
  account of the driver work.

- **DRP-AI userspace runtime.** The on-device inference runtime
  (`drpai-tvm-runtime`) is the Apache-2.0 DRP-AI TVM / MERA project
  (`github.com/renesas-rz/rzv_drp-ai_tvm`), fetched from a public
  git repository and packaged in-tree. No proprietary layer
  dependency for the runtime path.

## Revisit triggers

Re-open this decision when any of:

- CIP designates a new SLTS series past 6.12 and this platform is
  still within the 6.12 series' active maintenance window.
  (Move forward to the new frontier.)
- The vendor BSP for a board added to the platform moves off CIP
  onto a different base. (Re-evaluate per-board; may force a
  dual-kernel arrangement.)
- A driver dependency lands a 6.12-compatible port upstream or from
  the vendor. (Unblocks dependent work but does not by itself change
  the kernel base.)

## References

- [Civil Infrastructure Platform (CIP)](https://www.cip-project.org/) — SLTS kernel maintenance.
- [renesas-rz/rz_linux-cip](https://github.com/renesas-rz/rz_linux-cip) — Renesas RZ enablement on the CIP base.
