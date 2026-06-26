# ADR-0002: Layer hosting policy

- Status: Accepted
- Date: 2026-06-14

## Context

edge-ai-yocto, wrynose baseline, post-rename to the `edge-ai` distro.

## Decision

Upstream Yocto layers (`bitbake`, `openembedded-core`, `meta-arm`,
`meta-openembedded`, `meta-rauc`, `meta-renesas`, `meta-secure-core`,
`meta-security`, `meta-virtualization`, …) **must not** land at the
repo root. They are managed exclusively by kas and live under
`$KAS_WORK_DIR` (= `.kas/`), which is gitignored as a category.

The bitbake build dir is **not** in scope for this policy. It stays at
the traditional `build/` at repo root (set via `KAS_BUILD_DIR`) — the
universal Yocto convention every operator, tutorial, and `oe-init-...`
script references. Keeping it at the conventional location costs
nothing in this design (`build/` is one gitignored dir, not a per-layer
denylist), and aligns with operator muscle memory.

Acceleration uses `KAS_REPO_REF_DIR` (git alternates pointing at a
shared object cache). SHA pins declared in `kas/base.yml`'s `repos:`
blocks are the source of truth; the shared cache **does not** override
them — alternates only supply objects, kas still checks out the
declared SHA.

Floating upstream branches (e.g. `meta-rauc` on `wrynose`) are
captured by `kas lock` into a committed `kas/base.lock.yml`. Bumping
a floating branch is an explicit `make lock` + commit, not silent
drift.

## Rationale

### Vendoring upstream layers in the repo tree

Previously kas cloned every upstream into the repo root (`bitbake/`,
`openembedded-core/`, etc.), and `.gitignore` carried a hand-maintained
denylist naming each one. Rejected because:

- Adding a new dependency required editing `.gitignore` — easy to
  forget; reviewer noise on every layer addition.
- `ls` on the repo root showed two-dozen vendor directories,
  obscuring project content.
- A new operator with a stale `.gitignore` could accidentally `git add`
  an upstream layer and ship a 200 MB commit.

### `path:` overrides in `kas/local.yml`

kas supports a `path:` override on each `repos:` entry so the operator
can point kas at an existing on-disk clone. Rejected because **`path:`
loses SHA pin enforcement** — kas uses whatever HEAD the shared clone
happens to be at, not the SHA declared in `kas/base.yml`. Acceptable
for branch-only configs that don't SHA-pin; not acceptable here where
reproducibility is a CRA-posture commitment. `KAS_REPO_REF_DIR` gives
the same disk savings via git alternates while preserving pin
enforcement.

### Submodules

Considered briefly; rejected for the standard reasons (no benefit
over kas-managed clones, extra `git submodule update --init` step,
detached HEAD pitfalls, no way to pin a sparse subtree of a layer).
kas already does what submodules would do, with better ergonomics
for the Yocto-specific shape.

## Consequences

**Operator experience**

- First-time setup on a host **without** a shared cache:
  `kas shell kas/edge-autofetch.yml` (or `make shell` after copying
  `kas/local.yml.example` → `kas/local.yml`). All upstream layers
  fetch into `.kas/`. Repo root stays clean.
- Steady-state on a host **with** a shared cache:
  the Makefile defaults `KAS_REPO_REF_DIR` to a host-local, release-scoped
  layer cache (e.g. `…/layers-wrynose`). Override with
  `make dev KAS_REPO_REF_DIR=/your/path` or `export` for a per-host
  preference. Near-instant repo setup; SHA pins still enforced.
  Scoping by release line (`layers-wrynose`) keeps parallel
  scarthgap/kirkstone projects on the same host from cross-contaminating
  object pools (alternates are technically read-only and cross-release
  safe, but the isolation prevents force-push surprises showing up
  across unrelated projects).

  Note on storage placement: layers, downloads (`DL_DIR`), and sstate
  (`SSTATE_DIR`) are deliberately three independent paths so an operator
  can place each on the storage tier that fits. The defaults colocate all
  three on one fast-storage mount; operators set `KAS_REPO_REF_DIR` (in the
  environment) and `DL_DIR` / `SSTATE_DIR` (in `kas/local.yml`) to their
  own paths independently.
- Verifying drift: `make verify-pins` runs `kas for-all-repos … 'git
  rev-parse HEAD'` and prints the actual SHA each repo is at. Diff
  against `kas/base.yml` or `kas/base.lock.yml`.
- Standalone `kas` invocations (outside `make`): source
  `scripts/env.sh` once per shell session. The Makefile exports
  `KAS_WORK_DIR` + `KAS_REPO_REF_DIR` only to its own sub-processes;
  without the same vars in shell scope, a bare `kas shell` falls back
  to kas defaults (work-dir = CWD) and re-clones every upstream layer
  into the repo tree. The script is idempotent and pre-set values are
  respected.

**Adding a new upstream layer**

One edit: a new `repos:` block in `kas/base.yml`. **No** `.gitignore`
change (the new clone lands in `.kas/`, caught by the existing
category-level ignore). Optionally re-run `make lock` if the new
layer tracks a floating branch.

**Reproducibility**

`kas/base.lock.yml` (output of `make lock`) freezes floating
branches to a SHA at the moment of running. Committing the lock file
means every checkout of this commit can reconstruct the exact source
state of every upstream layer at that point in time. Pair with
deterministic `SOURCE_DATE_EPOCH` (already wired by oe-core) for full
bit-for-bit reproducibility.

## Notes

- `KAS_REPO_REF_DIR` is documented in kas as `repo_ref_dir` (kas docs
  → "Configuration Reference" → "Environment Variables"). It works
  with kas ≥ 3.0; we pin newer than that in CI.
- `kas lock` requires network access to resolve floating branches.
  It's not run at build time — only when the operator explicitly
  wants to bump pins.
- `kas purge` (the kas plugin) wipes `KAS_REPO_REF_DIR` contents in
  addition to `.kas/`; that's why our `make purge` does scoped `rm`
  directly instead of calling `kas purge`. See Makefile:`purge`.

## Follow-on work

Items raised during the restructure that we deliberately deferred —
each is a single-pass adoption when the time comes:

- **`buildtools:` adoption** — `kas/base.yml` `buildtools:` key (kas
  ≥ 5.0) pins the host toolchain bundle (gcc/python/ninja/…) by
  version + sha256. Decouples builds from host package state. Strong
  CRA-posture fit for release builds. Requires the kas 5 upgrade.
- **`signers:` + `signed: true`** — verify GPG signatures on each
  upstream layer's commit/tag before checkout. Hard CRA-posture
  statement; real setup cost (key distribution, signer policy).
- **Top-level `env:` for feature-gate passthrough** — when we add
  IOTGW-style runtime toggles, kas's top-level `env:` block forwards
  listed vars into `BB_ENV_PASSTHROUGH_ADDITIONS` automatically;
  replaces hand-wired Makefile passthrough.
- **`kas/sdk.yml` with `task: populate_sdk`** — dedicated stack
  fragment so `make sdk` becomes a one-line wrapper. Only useful once
  the SDK is a deliverable.
- **kas 5 upgrade** — fleet-wide decision deliberately isolated from
  the restructure. Brings buildtools support, the "fail on fetch
  errors" semantics, "warn about repos with branches but without
  commit or lock file", and the 5.3 CVE fixes.

## References

- [kas documentation](https://kas.readthedocs.io/) — setup tool for bitbake projects (layer composition, repo references / git alternates).
