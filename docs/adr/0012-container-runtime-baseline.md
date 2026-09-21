# ADR-0012: Container userspace is OS baseline, on every tier and machine

- Status: Accepted
- Date: 2026-09-09

## Context

The container runtime entered the platform as an opt-in capability: a kas
fragment adding `meta-virtualization`, selected per build. That framing
does not match how the platform actually uses containers.

The accelerator packagegroups install **Quadlet units** — the containerised
inference path is the delivery mechanism the model channel
([ADR-0010](0010-model-artifact-delivery.md)) targets. With the runtime
opt-in, an image can be built that contains the accelerator stack, its
device policy, its principal and its Quadlet, and cannot run any of it.
That failure is silent: the image builds green, boots, and exposes the
accelerator device, while the unit that would use it has no engine. Such an
image was produced during development, which is the evidence that an
opt-in default is the wrong one.

A capability flag is the right shape for something a product may or may not
want (JTAG debugging, BPF tooling, TPM). It is the wrong shape for
something the platform's own components depend on.

## Decision

**1. Container userspace is baseline for every image tier and every
machine.** `edge-image.bbclass` installs `packagegroup-edge-containers`
unconditionally. There is no flag.

**2. `meta-virtualization` is a base layer**, composed from `kas/base.yml`
alongside the other upstream layers, not from a capability fragment.

**3. Runtime policy is distro scope.** `DISTRO_FEATURES` carries
`virtualization`; the runtime picks (`crun`, `netavark`, `aardvark-dns`)
live in `edge-floor.inc` beside the rest of the distro floor.

**4. The prod tier is not an exception.** A hardened image that cannot run
the inference path it was built to run is not more secure, it is less
useful, and the divergence would only be discovered on hardware.

**5. The container principal is part of the container baseline, not of an
accelerator.** `edge-ctr-user` moves to `packagegroup-edge-containers`. It
was previously installed by the DRP-AI packagegroup, which made a
distro-level identity an artifact of one accelerator on one board.

**6. There is no off-switch.** A toggle defaulting to `1` (an
`EDGE_ENABLE_CONTAINERS`) was considered and rejected: it changes the
default but keeps the mechanism, and a platform dependency expressed as an
operator-selected flag fails on hardware rather than at build time when it
is eventually not selected. `VIRT=1` is retained as a warned no-op so
existing invocations keep working.

## Rationale

Baseline-vs-capability is decided by who depends on it. Nothing in the
platform depends on JTAG or BPF tooling; the accelerator stacks depend on a
container engine. A dependency expressed as an operator-selected flag is a
dependency that will eventually not be selected.

Point 4 is the one with a real cost, and it is accepted deliberately. Prod
gains podman, crun, netavark, aardvark-dns and their surface. The
alternative — prod opting out — produces two tiers whose accelerator
behaviour differs, so the tier that ships to devices is the one least
exercised in development. Divergence between the hardened tier and the
tested tier is the more dangerous failure.

Point 5 also fixes an ownership error: a rootless container principal is
container policy. Tying it to DRP-AI meant a second accelerator would have
had to either recreate it or depend on the first accelerator's
packagegroup.

## Consequences

- Every image grows by the container userspace, including prod.
- `DISTRO_FEATURES` gains `virtualization` platform-wide, which is a
  signature input for many recipes; expect a wide rebuild on adoption.
- `VIRT=1` and `kas/virtualization.yml` become no-ops, retained one release
  for compatibility and warned about at invocation.
- `meta-virtualization` becomes a hard dependency of the build. It must be
  fetchable for any build, including a second machine's.
- Prod's attack surface grows. CVE tracking now covers the container stack
  on every tier rather than only on images that opted in.
- An accelerator packagegroup may assume a container engine exists.

## Revisit triggers

- A product tier appears that genuinely runs no containers and for which
  the runtime's surface is unacceptable — then the toggle earns a
  tier-specific `0` rather than this ADR being reversed.
- The inference delivery mechanism stops being container-based.
