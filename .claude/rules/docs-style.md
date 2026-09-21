# Docs style — `docs/`, `README.md`, ADRs

Rules for prose under `docs/` and the top-level `README.md`. The audience is
someone using or evaluating the platform as it is, not someone following the
session that built it. Recipe, kas and script comments follow
`comment-style.md`.

## Baseline rule

**Docs describe the system that exists.** A capability enters the docs once it
is built and validated, in the same change that makes it true. Until then it is
not mentioned.

The "say plainly when a claim is unverified" rule in `AGENTS.md` §"Validating
behaviour changes" governs commit bodies and review claims. It does not license
scattering "not yet", "pending", "has not been re-validated" or "will follow"
through documentation.

## Prohibited patterns

### Progress-log prose

Docs are not a record of the build → run → debug loop.

```
# Wrong
Both are fixed in the same change as this doc; re-validation is pending.
Container auto-start needed two fixes, landing in this change set.
An earlier draft of this ADR kept a toggle.
It used to be the entry point; that was wrong.

# Correct
The image writes subuid/subgid ranges for edge-ctr at rootfs assembly.
A toggle defaulting to 1 was considered and rejected: <reason>.
```

### Scattered "not yet" caveats

```
# Wrong
Boot pending. Not yet booted. No inference payload has been staged yet.
The DX-M1 Quadlet will follow once a payload exists.

# Correct
(omit — describe what the Quadlet does and what it expects)
```

### References that do not belong in a public repo

No `scratch/` paths, no sibling or private project names, no build-host
identity (OS release, hostname), no board IPs. Evidence a reader cannot open
is not evidence.

### Session voice

No `we`, `our`, `I`, `you` narration of what happened; no "stated honestly",
"turned out", "we found".

## What is allowed

- **Present-tense limitations that change how the system is used or
  trusted.** State them as current properties, without "yet":
  "SELinux runs permissive on this image", "The rollback matrix has been run on
  RZ/V2L only", "Lockdown is compiled in but not activated".
- **Dated validation stamps**, matching existing docs:
  "Hardware-validated 2026-09-04", "Measured baseline (snapshot 2026-06-23)",
  with an image ID where one exists.
- **Measurements labelled with their board and conditions** — model, input
  size, mode, duration. A number without its conditions is not a benchmark.
- **ADR history as decision content** — alternatives considered and why they
  were rejected — written as the decision, not as drafting history.

## Where open work goes

One place per area: a `Roadmap` section in the area's top-level doc
(`docs/<area>/README.md`, or `README.md` for the platform). Not in every page,
not interleaved with the description of what works.

## ADR header

```
# ADR-NNNN: <title>

- Status: Accepted
- Date: YYYY-MM-DD
- Amends | Supersedes: ADR-NNNN, linked (when applicable)
```
