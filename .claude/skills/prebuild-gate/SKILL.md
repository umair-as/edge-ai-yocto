---
name: prebuild-gate
description: "Run the cheapest checks that exercise the current changes before an image or bundle build: make check, then targeted BitBake tasks (do_patch on touched recipes, kernel configure, the KSPP gate, or a parse) chosen by `make preflight`. Use before any `agent-build.py start` or `make base|dev|prod|bundle`, and after editing recipes, bbappends, patches, kernel fragments, kas files or distro config."
metadata:
  argument-hint: "[--board B] [--base REF] [--paths P ...]"
---

# Pre-build gate

An image build takes from minutes to hours; most defects that reach one would
have failed a targeted task in seconds or minutes: a patch that no longer
applies, a missing `file://`, a fragment the kernel drops, a parse error.
`make preflight` maps the changed paths to those tasks. This skill decides when
to run it and how to read the result.

## Run

1. **Plan, then host tier.** No BitBake, does not touch `build/`:
   ```bash
   make preflight PREFLIGHT_ARGS=--plan BOARD=<board>   # what would run, what is not covered
   make preflight BOARD=<board>                         # scripts/ci/check.sh (~10 s)
   ```
   Use the board the build is for. Paths that board's run does not exercise
   (another board's layer or include, a flag-only kas fragment or kernel
   fragment) are listed as "not covered on <board>" with the reason. Rerun for
   the right board, or with the flag (`make -n <target> BOARD=… <FLAG>=1`
   shows the composition), when they matter.

2. **BitBake tier, after coordinating.** Targeted tasks in the board's build dir:
   ```bash
   make preflight BOARD=<board> PREFLIGHT_ARGS=--bitbake
   ```
   - Confirm that no other agent or the operator owns the build host. The
     `no-parallel-bitbake` hook refuses while any bitbake runs on the host; the
     script exits 3 while any board's `bitbake.lock` or `.agent-build.lock` is
     held. Treat either as "wait", **never** as "remove the lock".
   - Exit 3 also covers a missing `kas/local.yml` (a fresh worktree: no shared
     DL_DIR/SSTATE_DIR). Seed it with the `yocto-worktree` skill; do not pass
     `--allow-cold` unless the operator asks for a cold run.
   - One targeted task replaces `parse` (BitBake parses everything first).
     Kernel configure runs at the dev tier; `kernel-hardening-check` covers the
     prod `.config`.
   - Recipes whose `COMPATIBLE_MACHINE` lists only other boards' machines are
     left out with a note. Family or override values are noted as "not
     decidable" and kept; if `do_patch` reports one skipped, rerun with
     `PREFLIGHT_ARGS="--bitbake --exclude-recipe <pn>"`.
   - A change under a recipe directory's `files/` also patches that
     directory's other recipes, whether or not they use the file. A pass there
     is not proof the file was applied; check the not-covered lines.

## Read the result

- **Exit 0:** the selected checks passed. Necessary, not sufficient (AGENTS.md
  "Validating behaviour changes"). `do_patch` proves patches apply and
  `file://` sources exist, not that their content is right.
- **Exit 1:** the failing check is named on the last line. Find the first
  causal error in its task log under `build/<board>/tmp/work/…/temp/` and fix
  it before the image build.
- **"no fast BitBake check for N path(s)":** only the image build, or the
  board, exercises them. When reporting, say so instead of implying they were
  checked.

## Extending

A new path class gets a rule in `classify()` in `scripts/ci/preflight.py` and a
case in `scripts/ci/preflight-selftest.py`. A new `dynamic-layers/<collection>`
needs a `COLLECTION_BOARDS` entry; the selftest fails until it has one. Host
selftests belong in `scripts/ci/check.sh`, which preflight runs as its host
tier. Keep one mapping.
