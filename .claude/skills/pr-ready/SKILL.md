---
name: pr-ready
description: "Take a finished branch to an open PR: hardware-validation gate, make check (and make ci when parsing can break), diff and commit-message hygiene, an independent review by a different-model subagent, then a short PR body with the RESULT line. Operator-invoked only."
disable-model-invocation: true
metadata:
  argument-hint: "[branch]"
---

# PR ready

Run the steps in order and stop at the first one that fails. Report what each
step showed. The rules live in AGENTS.md ("Branch strategy", "Commit style",
"Validating behaviour changes") and `docs/dev/ci.md`; this skill only orders
them.

1. **Hardware gate.** If the change affects runtime behaviour on a board
   (boot, OTA, kernel, services, accelerators), it needs on-target validation,
   failure cases included, before a PR. If that has not been done, stop and say
   what remains to be run. Docs, host tooling and parse-only changes skip this.

2. **State.** `git status` is clean and the branch is rebased on
   `origin/main` (`git fetch` first). The branch name follows `<scope>/<topic>`
   or `<type>/<topic>`.

3. **Gates.**
   - `make check`: keep the final `RESULT:` line verbatim.
   - `make ci` on the build host when the change can break parsing or a build
     (recipes, kas, classes, distro or machine conf). Coordinate first; it
     parses in a worktree.

4. **Hygiene** over `git diff origin/main...HEAD` and
   `git log origin/main..HEAD`:
   - no `scratch/` or other gitignored paths, no absolute `/home/` paths, no
     board IPs or host names, no sibling or private project names. Check the
     diff, the commit messages and the PR body. `make check` covers commit
     messages and `scripts/`/recipes, but not `docs/`.
   - every commit: Conventional Commit subject, no `Assisted-by:`, no AI
     `Co-Authored-By:`; the PR body has no generated-with footer.
   - behaviour changes: the commit body says what was run and what it showed,
     or says "unverified". No dates in check lines.
   - docs follow `.claude/rules/docs-style.md`: no progress-log prose, no
     volatile counts.

5. **Independent review.** Spawn the `yocto-rules-reviewer` agent on the
   branch diff for recipe, patch, kas and comment rules, and a general review
   on a model different from the one that wrote the change. Give the reviewers
   the diff, not your conclusions. Fix what they confirm, and re-run step 3 if
   anything changed. Record the verdict for the PR comment.

6. **PR.** Ask the operator before pushing. Body: what changed and why in a
   few lines, how it was validated, a **Workflow** section, and the `RESULT:`
   line. Keep internal gaps, parked work and known issues out of the public
   text. No generated-with footer.

   The Workflow section makes the agent-driven process visible, one line each
   (write "none" rather than omitting a line):
   - **Learn:** the mistake, finding or decision this change comes from.
   - **Guard:** the deterministic check added or changed, and the proof it
     rejects the bad case (fails on the old code) and accepts a good one.
   - **Review:** reviewer model(s), rounds, and the verdict, with a link to the
     PR comment that records it.
   - **Score:** what was measured against a baseline (differential run, eval
     scenario), or "not scored".

Merging is a separate step under the operator's merge rules; this skill ends
at an open PR.
