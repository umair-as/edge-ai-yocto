# Vulnerability-management workstream — architecture & decisions

Decision record for the CRA vulnerability-management workstream on this distro
(Yocto wrynose 6.0, smarc-rzv2l). Captures **what has been decided and why** —
not aspirational design. Anything unsettled is marked **OPEN**; where a section
would be speculation, it is written as an open question instead.

Companion to [`foss-cra-tooling-survey.md`](foss-cra-tooling-survey.md) (the
market survey the stack was chosen from), [`cra-spike-findings.md`](cra-spike-findings.md)
(the measured evidence), [`sbom-cve-triage.md`](sbom-cve-triage.md) (the
day-to-day workflow), and [`CRA-CONTROLS.md`](CRA-CONTROLS.md) (Annex I mapping).

*Point-in-time; the build, tool versions, and the standards landscape were all
moving. Re-verify load-bearing claims before betting on them.*

---

## 1. Pipeline (as decided)

```
create-spdx (SPDX 3.0.1) ─┐
                          ├─► sbom-cve-check (Bootlin) ──► *.sbom-cve-check.{yocto,spdx}.json
CVE_STATUS[...] (in-tree) ┘            │
                                       ├─► sbom-cve-report.py   (summarise / CSV / status scaffold)
rootfs ──► grype dir: ────────────────┼─► cve-reconcile.py     (breadth delta vs sbom-cve-check)
                                       └─► cve-triage-funnel.py (volume → ranked human worklist)
```

- **In-tree CVE engine:** `sbom-cve-check` (Bootlin, GPLv2), already wired in the
  edge distro; re-scans without a full rebuild, consumes `CVE_STATUS`/VEX.
- **SBOM:** SPDX 3.0.1 via `create-spdx`. No production scanner ingests SPDX
  3.0.1 (survey §2) — so scanners are fed the **rootfs** directly, not the SBOM.
- **Breadth scanner:** Grype (`dir:` over the extracted rootfs). Provisional GO
  (Stage-1 verdict); see OPEN-4.
- **Analysis scripts** (stdlib-only, read-only over `build/tmp/deploy`):
  `scripts/sbom-cve-report.py`, `scripts/cve-reconcile.py`,
  `scripts/cve-triage-funnel.py`. Scanner pins:
  `scripts/install-scanners.sh` (binaries gitignored under `.tooling/`).

---

## 2. Decisions

### D1 — The triage funnel sets the volume / human-judgment boundary
**Decision.** `cve-triage-funnel.py` absorbs the mechanical majority of Unpatched
findings and escalates only what needs human reachability/posture judgement.
The boundary is explicit:

| Stage | Handles | Outcome |
|---|---|---|
| Kernel set-aside | `linux-renesas` CVEs | parked as one line (OPEN-7) |
| Fan-out collapse | same CVE across packages sharing `CVE_PRODUCT` | N rows → 1 decision-unit; redundant rows absorbed |
| Version-clearable (B1) | clean upstream fix boundary known **and** installed ≥ fix | auto-**proposes** `fixed-version` |
| Ambiguous boundary (B1-confirm) | `version-maybe-in-range`, fix fuzzy | proposes only with a fix to lean on; always NEEDS-CONFIRM |
| Escalate (B3) | `no-version-ranges`, genuinely-in-range, posture-gated | ranked worklist with evidence; **no verdict** |

**Why.** The raw Unpatched count (point-in-time: 475, of which 397 kernel) is not
a worklist — most of it is fan-out duplication, kernel noise, or version
false-positives. The funnel turns it into a small list of genuine judgement
calls (point-in-time: ~36 userland), each pre-loaded with the package that holds
the vulnerable code, CVSS vector, fix-info, and suggested on-target checks.
**Status: decided, implemented.** Observed reality: B1/B1-confirm are near-empty
because the local DB rarely carries clean upstream fix boundaries — the funnel's
leverage is fan-out + kernel set-aside + evidence-gathering, not auto-clearing.

### D2 — Two record loci; what dictates which
**Decision.** A ratified `CVE_STATUS` decision lands in one of two places, chosen
by the *shape* of the false positive:

- **Per-recipe `.bbappend`** — recipe-specific decision (the CVE concerns one
  recipe). *Implemented:* `meta-edge-bsp/recipes-devtools/rsync/rsync_%.bbappend`
  (CVE-2024-12084).
- **Distro-wide `edge-cve-ignores.inc`** — a false positive that spans a whole
  upstream family via a **shared `CVE_PRODUCT`** (one CVE smears across N
  packages). One line covers the family. *Designed locus; not yet instantiated
  — see OPEN-5.*

**Why.** The SELinux family shares `CVE_PRODUCT = "selinux_project:selinux"`
(`selinux_common.inc`), so a single CVE matches ~11 packages. A per-recipe
bbappend would mean 11 identical files; the distro-wide include is one line. The
discriminator is therefore *"recipe-specific vs. family-wide via shared
CVE_PRODUCT"*, not severity or status. **Status: rule decided; per-recipe path
implemented; distro-wide path designed, instantiation OPEN.**

### D3 — Status truth over cosmetics
**Decision.** The `CVE_STATUS` chosen must be the *accurate* one, even when an
accurate status does not change the report. Specifically:
- `fixed-version` is used when the shipped version carries the fix (rsync 3.4.1;
  SELinux 3.10) — **even though it does not flip the Bootlin count** (see §3).
- `cpe-incorrect` / `ignored` are **not** chosen to force a count change. For the
  SELinux cluster, `cpe-incorrect` was explicitly rejected: the CPE genuinely
  matches via the shared umbrella product, so it would be a false statement.

**Why.** The in-tree decision is the audit record; gaming it for a cosmetic
count change corrupts the very thing CRA vulnerability-handling evidence rests
on. **Status: decided.**

### D4 — Human-in-the-loop: tool proposes, human ratifies
**Decision.** No automated tool writes `CVE_STATUS`. The funnel and reconciler
*propose*; a human ratifies and places the line. Proposals derived from build
metadata are stamped **`UNVERIFIED — confirm on target`** and are never presented
as verified (build metadata ≠ the running board). Posture-dependent items are
held visible-and-undecided, never pre-cleared.
**Why.** Suppression is a security assertion; it requires human accountability,
and the on-target reality (service running? port open? enforcing?) is not in the
build metadata. **Status: decided, enforced by construction in the tooling.**

### D5 — Grype for breadth; rootfs as the scan target
**Decision.** Grype scans the extracted rootfs (`grype dir:`), reconciled against
`sbom-cve-check` by package+CVE identity (`cve-reconcile.py`).
**Why.** Stage-1 measured Grype surfacing CVEs absent from `sbom-cve-check`
entirely in the **vendored Go-dependency layer** (e.g. podman's bundled modules)
that recipe→CPE scanning is structurally blind to. **Status: provisional GO
(Stage-1).** Full adoption is gated on OPEN-4 (OS-package parity), because the
measured run had grype's OS-package matchers disabled by failed distro detection.

### D6 — Kernel deferred; userland first
**Decision.** Kernel (`linux-renesas`) CVEs are set aside as a single line, not
triaged in the userland funnel.
**Why.** They dominate the count (point-in-time 397/475) and need a different
method — config-reachability ("is that subsystem/driver even compiled in?") — not
version/fan-out logic. **Status: decided for now; see OPEN-7.**

### D7 — Fix-version source = the build's local CVE DB
**Decision.** Fix boundaries for version logic come from the build's local
`nvd-fkie` + `cvelist` databases (`build/tmp/deploy/sbom-cve-check/databases`),
not online NVD.
**Why.** Authoritative, offline, and *matches the exact report* under triage.
**Status: decided.** Observed limit: these DBs frequently carry only discrete
affected versions (no `versionEndExcluding`/`lessThan`), which is why most
version cases cannot auto-clear and honestly escalate.

---

## 3. Key finding: the CVE_STATUS propagation gap (grype --vex is load-bearing)

**Finding.** A `CVE_STATUS = "fixed-version"` decision is *invisible* to the
`sbom-cve-check` report. `SPDX_INCLUDE_VEX="current"` (default) excludes
already-fixed CVEs from the emitted VEX, so the Bootlin re-scanner sees no
assertion and re-derives the finding from NVD (often ambiguous → stays
Unpatched). The accurate, truthful status therefore does **not** reduce the
report's count.

**Decided consequence.** Real, demonstrable suppression of fixed/not-affected
findings is expected to come from the **OpenVEX → `grype --vex`** path, not from
the Bootlin report. That makes the VEX-export + Grype layer *load-bearing* for
suppression, not merely additional breadth. The in-tree `fixed-version` decision
is kept (truth, and it is the audit record); the report's residual entry is
documented as a known artifact, not an unresolved exposure.

**Caveat (do not over-read).** That `grype --vex` actually suppresses these
end-to-end is **designed, not yet proven** — see OPEN-8. Detail and the traced
mechanism live in [`cra-spike-findings.md`](cra-spike-findings.md). This gap is
distinct from the survey-§6 *vocabulary* gap (no VEX justification exists for
`disputed`/`cpe-incorrect`/`abandoned`): this is a **propagation** gap (the
status maps cleanly but doesn't survive transit).

---

## 4. OPEN questions (unsettled — decisions not yet made)

**OPEN-1 — SELinux enforcing vs. permissive (posture).** The image currently
ships `SELINUX=permissive` (kernel `/sys/fs/selinux/enforce = 0`); SELinux is
otherwise fully wired (custom `selinux-init`/`autorelabel`/`labeldev`). Whether
to move to enforcing is an operator decision. It *gates* the reachability verdict
of SELinux-enforcement CVEs. The funnel tags affected items `GATED:selinux-posture`
and leaves them undecided. **Owner: operator.**

**OPEN-2 — On-device policy compilation (posture).** Whether SELinux policy is
compiled/loaded on the device gates CIL/`checkpolicy`/`libsepol` policy-path
CVEs. Tagged `GATED:policy-compilation`. **Owner: operator.**

**OPEN-3 — Inherited vs. affirmed suppression.** The bulk of currently-Ignored
CVEs (point-in-time 886) are **inherited from upstream layers** (oe-core,
meta-renesas `CVE_STATUS`), not decisions made in this repo — at the spike's
start the in-tree decision surface was empty (it now holds the rsync entry).
Open question: do inherited suppressions get **audited/affirmed** as part of this
distro's posture, or trusted as-is? This is a governance decision, not a
technical one, and it is unmade.

**OPEN-4 — Grype OS-package parity.** The Stage-1 grype run had OS-package
(`rpm`) matchers disabled because distro detection failed on `ID=edge-ai`. The
breadth finding therefore covers only the Go layer; OS-package behaviour is
untested. A `grype --distro` re-run is needed before drawing OS-layer
conclusions or fully committing to Grype (D5).

**OPEN-5 — `edge-cve-ignores.inc` creation + wiring.** The distro-wide locus
(D2) is designed but the file does not exist, and wiring it (a `require` from the
distro conf) is a build-config change reserved to the operator. Until then,
family-wide decisions (e.g. the SELinux cluster) are **not recorded**.

**OPEN-6 — `SPDX_INCLUDE_VEX`: `current` vs `all`.** Setting `all` would emit
`VexFixed` assertions that *might* let the Bootlin report honour `fixed-version`
(closing the §3 propagation gap at the report level), at the cost of larger/
slower SPDX generation. Whether the Bootlin tool actually honours `VexFixed` is
unverified. Build-config change; not made.

**OPEN-7 — Kernel config-reachability stream.** The deferred 397 kernel CVEs need
a dedicated method: cross-reference each CVE's subsystem against the kernel
`.config` to separate "compiled-in and reachable" from "not built". Not scoped
yet; gated on a *kernel-config-trust* posture call (is config-pruning an
acceptable suppression basis?).

**OPEN-8 — Stage 2/3 unproven.** OpenVEX export (`yocto-vex-check`),
`grype --vex` suppression (the §3 load-bearing path), and VulnScout aggregation
are designed but not yet executed/measured. Until run, end-to-end suppression is
a plan, not a demonstrated capability.

**OPEN-9 — Funnel: already-ratified filter.** The funnel does not yet read
in-tree `CVE_STATUS`, so already-decided CVEs (e.g. rsync) re-surface in the
worklist (compounded by the §3 propagation gap keeping them Unpatched in the
report). Adding an "already ratified" pass is what makes the worklist *converge*
as decisions accrue. Proposed, not built.

---

## 5. Out of scope here
Format-conversion strategy, dashboard choice (Dependency-Track), and the
commercial-vs-FOSS intelligence comparison are covered in the survey, not
re-decided here. Nothing in this document mandates a tool the workstream has not
already adopted.
