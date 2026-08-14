# Guarded research-subagent brief — template

A reusable structure for briefing a fan-out research/analysis subagent when the
task is security- or correctness-sensitive and a naive agent would optimize the
wrong thing (e.g. "make the CVE count go down" instead of "produce a defensible
trail"). The guardrails go **first**, before the task, so the agent reads the
constraints before forming an approach.

The pattern generalizes beyond security — any time you delegate research where
the easy win is the wrong win, front-load the anti-goal.

## The reusable structure

1. **Role + read-only scope, one line.** State the hat ("You are a kernel
   security engineer…") and that it is read-only: no repo changes, no builds,
   no commits. Side-effect-free research + a written deliverable.

2. **HARD GUARDRAILS first — before the task.** The most important block. State:
   - **The real objective and the anti-goal**, bluntly. "The objective is an
     auditable, evidence-backed trail — NOT reducing the count. A lower number
     that isn't defensible is a FAILURE, not a success."
   - **Evidence + accurate-labelling requirement.** Every output must be
     evidence-backed and honestly labelled; anything unbackable escalates to a
     human — never fudged to a "tool-honoured but inaccurate" value to make a
     finding disappear.
   - **The domain-specific trap, named.** Call out the exact failure mode the
     naive approach hits (e.g. "this is a CIP *backport fork*; CNA data is
     *mainline*, so a naive `fixed-version` can be flat wrong"). Naming the trap
     is what stops the agent walking into it confidently.
   - **Honesty clause.** "Be honest about limits and uncertainty; where unsure,
     say so rather than guessing."

3. **What to study — with REAL, verifiable targets.** Point at actual files,
   paths, repos, and the technique to read them (e.g. `git -C <mirror> show
   HEAD:<file>` for a bare mirror). Not "research X" — exact sources, so the
   agent can't substitute plausible-sounding invention.

4. **Repo/system context.** The specific current state the plan must fit: what's
   already configured, the real numbers, the existing mechanism and the
   principles (here: the repo's D3/D4) any recommendation must be consistent
   with.

5. **Deliverable spec — structured, with an explicit honesty section.** Enumerate
   the sections wanted, and require an "honest scope / what I could NOT
   determine" item so gaps surface instead of being papered over.

6. **Close on citations + uncertainty.** "Cite exact paths, line references, and
   URLs. Where uncertain, say so rather than guessing."

## When to use it

- The task's easy metric diverges from the real goal (count vs. defensibility,
  green CI vs. correctness, coverage vs. truth).
- A domain has a known trap a general agent won't know (fork-vs-mainline,
  point-release drift, permissive-mode reachability, clamped timestamps).
- The output will feed an auditable/committed artifact, so hand-waving is costly.

Pair with `parallel research fan-out` when the surface is broad: give each agent
one cluster and the same guardrail header, then synthesize and adversarially
re-check before trusting.

## Worked example — the kernel-CVE config-reachability brief

The brief that produced the kernel-side CVE-triage plan (OQ-5). Reuse the
*shape*; swap the domain specifics.

```text
You are a kernel security engineer producing an implementation plan for handling
Linux-kernel CVE false-positives in a Yocto build. This is read-only research +
a written plan — do NOT modify the repo, do NOT run builds, do NOT commit.

## HARD GUARDRAILS (read first, these override any instinct to "make numbers go down")
- The objective is an auditable, defensible vulnerability-handling trail that
  follows best security practice — NOT reducing the CVE count or CVSS totals. A
  lower number that isn't defensible is a FAILURE, not a success.
- Every proposed exclusion must be evidence-backed and human-ratifiable, recorded
  as a CVE_STATUS with the *accurate* reason-key. Distinguish rigorously:
  - not-applicable-config — only when the vulnerable source file is genuinely NOT
    compiled into this kernel (evidence = the compiled-source list).
  - fixed-version / rejected — only from authoritative kernel-CNA data.
  - Anything you cannot back with evidence stays UNPATCHED and escalates to a
    human. Never propose a blanket ignore; never pick a "tool-honored but
    inaccurate" status to make a finding disappear.
- Flag the CIP-fork trap explicitly. The kernel is linux-renesas = CIP 6.12 SLTS
  (a backport fork), NOT mainline. The kernel CNA vulns data tracks *mainline*
  fix versions, so a CNA-derived fixed-version can be WRONG for a fork that
  backported earlier. Call out where its output must NOT be trusted for CIP
  without human verification.
- Be honest about limits and uncertainty. If the "70-80% reduction" claim rests
  on assumptions that don't hold for a CIP fork or this config, say so.

## What to study (use the real sources)
[the security-manual URL; the two oe-core scripts, read from the real wrynose
oe-core mirror via `git -C <mirror> show HEAD:<file>`; the kernel CNA vulns repo]

## Repo context (the branch this plan targets)
[kernel recipe bbappend path; SPDX_INCLUDE_COMPILED_SOURCES already set at
edge-floor.inc:160; the 387 untriaged kernel CVEs (OQ-5); the existing
CVE_STATUS mechanism and the D3/D4 principles the plan must fit]

## Deliverable (a written plan, no code changes)
1. What each script actually does — inputs/outputs/decision logic, reason-keys.
2. The auditable workflow for this branch, and where generated exclusions live.
3. The CIP-fork correctness analysis — safe vs. unsafe statuses + the human check.
4. Honest scope — how many of the 387 this resolves, by which key, what remains.
5. A phased, reviewable rollout consistent with D3/D4; guard against count-gaming.

Cite exact paths, line references, URLs. Where uncertain, say so rather than guessing.
```
