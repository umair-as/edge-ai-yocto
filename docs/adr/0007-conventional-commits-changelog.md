# ADR-0007: Conventional Commits feeding automated release notes

- Status: Accepted
- Date: 2026-06-25

## Context

Releases are annotated `vMAJOR.MINOR.PATCH` tags (see `AGENTS.md`
§"Branch strategy"); the tag, `DISTRO_VERSION`, and the RAUC bundle
version must agree. Each release needs human-readable notes describing
what changed. Hand-writing them per release is the kind of recurring
manual step that rots — notes drift from the actual commit set, or get
skipped under time pressure.

The commit history is already, in practice, Conventional Commits:
`<type>(<scope>): <subject>`, with hierarchical scopes such as
`bsp/kernel` and `bsp/drpai`. At the time of this decision
every commit in the tree conforms. That regularity is machine-parseable
— a generator can group commits by type and render release notes
deterministically — but only for as long as the regularity holds. An
informal convention that is not enforced degrades the moment a
non-conforming subject lands, and the generator silently drops it.

## Decision

Adopt Conventional Commits as the **enforced** commit format, and
derive release notes from it automatically.

1. **Format.** `<type>(<scope>): <subject>`. Types: `feat`, `fix`,
   `docs`, `build`, `chore`, `ci`, `style`, `perf`, `refactor`, `test`,
   `revert`. Scopes are the layer/area names (the set in `AGENTS.md`)
   and may contain `/` and `-` (`bsp/kernel`, `rauc-ota`); `+` is not
   accepted by the commit-msg hook's default scope charset. Subject is
   imperative mood, no trailing period.

2. **Generation.** `cliff.toml` at the repo root configures
   [git-cliff](https://github.com/orhun/git-cliff) (pinned 2.13.1): a
   Conventional-Commit parser, type-based grouping
   (Features / Bug Fixes / …), and GitHub commit/compare links. Grouping
   is by type only — deliberately not by scope — so the config lifts
   unchanged to sibling repos.

3. **Publication.** `.github/workflows/release-notes.yml` triggers on
   `v`-semver tags, runs git-cliff `--latest`, and publishes the result
   as the GitHub Release body. Release-notes-only: `CHANGELOG.md` is not
   committed back to the branch. The built-in `GITHUB_TOKEN`
   (`contents: write`) is the only credential; no new secret.

4. **Enforcement.** `.pre-commit-config.yaml` runs
   `conventional-pre-commit` (pinned v4.4.0) at the `commit-msg` stage,
   rejecting non-conforming subjects at commit time. Its allowed-type
   list is the same list as item 1.

## Rationale

- **Why enforce, not just document.** The generator's output quality is
  a direct function of commit hygiene. A documented-but-unchecked
  convention fails open — a malformed subject is dropped from the notes
  with no error. A `commit-msg` hook fails closed: the bad commit never
  forms. The enforcement is what makes the automation trustworthy.

- **Why git-cliff.** It parses Conventional Commits natively, is a
  single pinnable binary (no language runtime in CI), and renders via a
  Tera template kept in-tree — the format is reviewable and version-
  controlled, not buried in an action's defaults.

- **Why release-notes-only.** Committing a regenerated `CHANGELOG.md`
  back from a tag push means committing from a detached tag ref onto a
  protected, linear `main` — a fragile dance against branch protection.
  The GitHub Release body is the canonical artifact; the full history is
  always reproducible from the tags by running git-cliff locally.

- **Why type-only grouping.** Scope-based grouping would bake this
  repo's layer names into the config and break portability. Type-based
  grouping is universal; the same `cliff.toml` and workflow drop into
  the Rust crate repos with only the GitHub slug (auto-injected) and the
  tag glob to review.

## Consequences

**Positive.**

- Release notes are a byproduct of normal work, not a release-day chore;
  they cannot drift from the commit set because they are generated from
  it.
- The commit log gains a second consumer (the changelog) on top of
  history/blame, which raises the baseline quality of subjects.
- The whole mechanism is three committed, pinned files — reproducible CI,
  no "latest"-tag surprises, portable to sibling repos.

**Negative.**

- Every commit now passes a format gate. A genuinely unconventional
  commit (e.g. a bulk import) needs `git commit --no-verify` as a
  conscious override.
- The convention now has hard dependencies: `cliff.toml`'s
  `commit_parsers` and `.pre-commit-config.yaml`'s allowed-type list
  must stay in sync with the type list here. The cliff.toml carries a
  back-reference comment to this ADR to flag the coupling.
- The `commit-msg` hook is opt-in per clone (`pre-commit install
  --hook-type commit-msg`); a contributor who skips that step is
  unchecked locally until CI or review catches a malformed subject.

## Revisit triggers

- A breaking-change release (`feat!:` / `BREAKING CHANGE:` footer) — the
  parsers reserve a Breaking group but it has never rendered; verify it
  on first use.
- Adopting CHANGELOG.md committed back in-tree (reversing decision 3)
  would need the detached-ref + branch-protection handling deferred here.
- A move to merge-queue / squash-merge PRs changes where the canonical
  subject is authored (PR title vs. commit), which may shift enforcement
  from `commit-msg` to a PR-title check.

## References

- [Conventional Commits](https://www.conventionalcommits.org/) — the commit-message specification.
- [git-cliff](https://github.com/orhun/git-cliff) — changelog generator (pinned 2.13.1).
- [conventional-pre-commit](https://github.com/compilerla/conventional-pre-commit) — the commit-msg enforcement hook.
