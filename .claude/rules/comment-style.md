# Comment style — recipes, kas, scripts

Rules for comments in any file that lands in `meta-edge-bsp/`,
`meta-edge-distro/`, `kas/`, or `scripts/`. The audience is a
maintainer reading the file months later, not the session that wrote it.

## Baseline rule

OE-Core convention: **terse fact-stating**. A comment states a non-obvious
constraint, invariant, or workaround — and nothing else. If removing the
comment wouldn't confuse a future maintainer, don't write it.

If a comment block exceeds ~4 lines, the rationale belongs in `docs/adr/`;
the inline comment can cite the ADR number but must not re-embed the prose.

## Prohibited patterns

### First-person pronouns

Recipe and config comments are file-scoped facts, not session transcripts.
No `we`, `our`, `I`, `you`.

```
# Wrong
# We add a multi-user.target.wants symlink so weston auto-starts.
# our smarc-rzv2l patches fail do_patch there.

# Correct
# graphical.target is not the default; add multi-user.target.wants so
# weston auto-starts.
# smarc-rzv2l patches fail do_patch against denx mainline master.
```

### Dated bench observations

Never embed a session date or bench-specific observation. These rot
immediately and expose debugging history that belongs in git log, not source.

```
# Wrong
# observed on this bench (2026-06-12): only ssh_host_ecdsa_key was generated.
# 2025: there is no scenario where this is wanted on a server.

# Correct
# in practice only ssh_host_ecdsa_key was generated.
# Not applicable on edge/server nodes.
```

### Directive / advisory tone

A comment states what IS, not what a future reader should DO. Replace
"should", "if you", "flip to", "when you want" with the factual state.

```
# Wrong
# Prod images should ship a drop-in that sets PasswordAuthentication no.
# If you change source pin or platform flags there, mirror them here.
# Flip to 1 for prod-debug + prod tiers.

# Correct
# Prod tiers set PasswordAuthentication no via a tier-specific drop-in.
# Source pin and platform flags must match optee-os_%.bbappend.
# 0 here; prod-debug + prod tiers set 1 via a tier sysctl.d drop-in.
```

### Editorial / chatty phrasing

No conversational quotes, informal adjectives ("generous", "chatty"),
or opinion-stamped summaries.

```
# Wrong
# "what should I SSH to next time" on a multi-NIC box.
# generous for legitimate logging and tight enough to catch a runaway loop.

# Correct
# egress IP for default route — address to reach this board on a multi-NIC setup.
# 1000 messages per 30s per unit — above normal volume, detects runaway producers.
```

## What belongs in a comment

A comment is correct and expected when:

- **A non-obvious invariant** — "`-` prefix tells sysctl to ignore the key
  if absent; mainline CIP 6.12 doesn't expose this knob."
- **A worked-around upstream bug** — "meta-renesas sets `S = ${WORKDIR}/git`;
  wrynose rejects that path. Override here to survive version bumps."
- **A maintained coupling** — "Source pin and platform flags must match
  `optee-os_%.bbappend`." (tells the maintainer what to keep in sync)
- **A non-obvious BitBake trap** — "systemd-sysctl(8) does NOT strip trailing
  `#…` — inline comments on value lines silently corrupt the key."

These are facts that would surprise a reader. Everything else is noise.

## Recipe DESCRIPTION / SUMMARY

`DESCRIPTION` is a package-manager field (≤3 wrapped lines), not a design
rationale block. See `recipe-metadata.md` for the canonical header layout
and length constraints.
