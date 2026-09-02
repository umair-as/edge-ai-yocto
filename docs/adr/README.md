# Architecture Decision Records

This directory holds the architecture decision records (ADRs) for
edge-ai-yocto — durable records of choices that shape the platform
and the reasoning behind them.

## Convention

- Filename: `NNNN-short-title.md`, numbered sequentially from `0001`.
  New ADRs get the next unused number — no year prefix, no gaps.
- Shape: classic Nygard-style (lightweight) — `Status`, `Context`,
  `Decision`, `Rationale`, `Consequences`. Add `Revisit triggers` and
  topic notes when they help; omit when they don't.
- Status values: `Proposed`, `Accepted`, `Superseded by ADR-NNNN`,
  `Deprecated`. Once an ADR is `Accepted` it is not edited in place
  except for typo / link fixes; a reversed decision is recorded as a
  new ADR that supersedes the old one.
- Public-repo discipline applies: no sibling-project names,
  portal-drop paths, personal paths, or employer-specific context.
  ADRs describe the decision in platform terms, not operator terms.

## Index

- [ADR-0001](0001-kernel-base.md) — kernel base (linux-cip 6.12 SLTS)
- [ADR-0002](0002-layer-hosting.md) — layer hosting (kas-managed `.kas/`)
- [ADR-0003](0003-block-layer-integrity-confidentiality.md) — block-layer integrity + confidentiality
- [ADR-0004](0004-persistent-state-architecture.md) — persistent state architecture
- [ADR-0005](0005-image-class-ota-backend.md) — image class + OTA backend
- [ADR-0006](0006-emmc-gpt-boot-target.md) — eMMC/GPT boot target
- [ADR-0007](0007-conventional-commits-changelog.md) — Conventional Commits feeding automated release notes
- [ADR-0008](0008-runtime-rootfs-verity.md) — runtime rootfs dm-verity
