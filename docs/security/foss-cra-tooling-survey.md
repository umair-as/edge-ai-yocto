# FOSS CRA vulnerability-management tooling — market survey

*Point-in-time market survey, mid-2026. Captured from two adversarially
verified deep-research passes (26 + 17 sources, 47 verified claims). This is a
**snapshot** — tool versions, format support, and the CRA standards landscape
were all moving at the cutoff. Re-verify anything load-bearing before betting
on it.*

**Why this doc exists:** to decide the OSS building blocks for a CRA-ready
vulnerability-management pipeline on this distro (Yocto wrynose 6.0 →
`sbom-cve-check` artifacts + SPDX 3.0.1 + in-tree `CVE_STATUS[...]`), and to
have an honest, evidence-backed view of the stack's strengths and limits —
without re-running the research.

Companion to [`sbom-cve-triage.md`](sbom-cve-triage.md) (the workflow we run
today) and [`CRA-CONTROLS.md`](CRA-CONTROLS.md) (Annex I mapping). Vulnerability
handling here maps to the EN 40000-1-3 horizontal.

---

## 0. TL;DR

- **The SPDX 3.0.1 conversion problem is real but avoidable.** No production
  scanner ingests SPDX 3.0.1 JSON-LD, and no mature converter reads it. *Don't
  build a pipeline on SPDX-3→CycloneDX conversion.* Scan the rootfs directly
  and/or generate CycloneDX natively.
- **The VEX "spine" largely already exists upstream.** Yocto can export
  `CVE_STATUS[...]` → OpenVEX today (`vex.bbclass`, `SPDX_INCLUDE_VEX`,
  `yocto-vex-check`). Grype consumes OpenVEX to suppress findings.
- **The aggregation/triage tool we'd otherwise build also exists:**
  **VulnScout** (`meta-vulnscout`) ingests our exact artifacts and exports VEX.
- **The genuinely unsolved problem** — and the place to add value — is that
  Yocto→VEX export is *lossy*: `cpe-incorrect` / `disputed` /
  `abandoned-project` have no justification in any VEX format.
- **Honest limits:** the stack is strong on monitoring, VEX suppression,
  SPDX-3-native triage, and cost; the real gaps are curated commercial-grade
  vuln intelligence and a single dashboard fluent in SPDX 3.0.1.

---

## 1. CRA context (what's actually mandated, and when)

| Date | Obligation |
|---|---|
| **11 Sep 2026** | Vulnerability/incident **reporting** obligations live: 24 h early warning / 72 h notification / 14 d final report, routed through ENISA's Single Reporting Platform. The near-term hard deadline. |
| **11 Dec 2027** | **Full** obligations, including SBOM / Annex I essential requirements. |

**Important nuance:** as of mid-2026 the CRA does **not** legally pin a
machine-readable SBOM format to SPDX *or* CycloneDX — that flows through
harmonised standards / ENISA technical guidance still emerging at the cutoff.
So *don't over-invest in format purity; invest in the triage + reporting
workflow.* (Sources: EC `cra-reporting`, ENISA SRP page.)

---

## 2. Format reality (round 1)

**Confirmed: SPDX 3.0.1 ingestion and SPDX-3→CycloneDX conversion are immature.**

- Production scanners (Trivy, Grype, OSV families) ingest **SPDX 2.2/2.3 +
  CycloneDX 1.4–1.6 only**. Trivy's docs list no SPDX 3.0.1 JSON-LD path.
- No surveyed converter reads SPDX 3.0.1 JSON-LD:
  - `protobom` / `sbom-convert` — SPDX **2.3** ↔ CycloneDX 1.4 only (pre-1.0).
  - `cyclonedx-cli` — SPDX **2.3** only, lossy, documented PURL drop (issue #424).
  - `syft` — SPDX **2.3** only; "preserves PURLs/CPEs" claim **refuted 0-3**.
  - `lib4sbom 0.10.4` — the *only* one that parses SPDX 3.0.1, **self-classified
    alpha**, gated behind `LIB4SBOM_SPDX3`.

**Consequence for this repo:** feed scanners the **rootfs** (`grype dir:`,
`trivy rootfs`) or a **natively-generated CycloneDX** (`meta-cyclonedx`,
iris-GmbH) — never a converted SPDX 3.0.1.

---

## 3. FOSS reference architecture (round 2)

| Stage | FOSS pick | Status mid-2026 | Note |
|---|---|---|---|
| **Generate** | `create-spdx` (SPDX 3.0.1) + `meta-cyclonedx` (CycloneDX 1.6) | in-tree / layer | dual-format: give each downstream tool what it ingests |
| **Detect (primary)** | `sbom-cve-check` (Bootlin, GPLv2) | Yocto 6.0, v1.2.0 | **we run this**; re-scan without rebuild; parses SPDX 2.2/3.0; consumes OpenVEX |
| **Detect (breadth)** | Grype `dir:`/rootfs `--vex` + OSV-Scanner v2 | mature | DB diversity vs cve-check's NVD-only; closes excluded-layer blind spots |
| **VEX spine** | `vex.bbclass` / `SPDX_INCLUDE_VEX` / `yocto-vex-check` → OpenVEX | upstream | `CVE_STATUS` → OpenVEX, already there |
| **Aggregate + triage UI** | **VulnScout** + `meta-vulnscout` (Savoir-faire Linux) | active, v0.8.1 | the integration centerpiece; SPDX-3-native; ingests cve-check JSON + Grype JSON |
| **Fleet dashboard** | Dependency-Track v5 (optional) | GA Jun 2026 | **CycloneDX-only** → needs the CDX feed; continuous portfolio re-analysis |
| **Quality score** | sbomqs / sbom-utility | **not verified** | survey did not confirm SPDX 3.0.1 support — open question |

Data flow:

```
create-spdx (SPDX 3.0.1) ─┐
meta-cyclonedx (CDX 1.6) ─┤
                          ├─► sbom-cve-check ──┐
rootfs ──► Grype --vex ───┤                    ├─► VulnScout ──► triage UI
       └─► OSV-Scanner ────┘                    │   (dedup +      + OpenVEX /
                                                │    VEX apply)     SPDX / CDX
CVE_STATUS[...] ─► vex.bbclass ─► OpenVEX ──────┘                      │
                                                                       └─► (CDX) ─► Dependency-Track v5
```

---

## 4. Tool-by-tool findings

### Dependency-Track v5 (Hyades) — the dashboard
- GA **June 2026**, Apache-2.0, self-hostable (docker-compose), continuous
  portfolio re-analysis as new CVEs/policy land. Vuln intel: NVD, GitHub
  Advisories, Sonatype OSS Index, OSV, optional paid VulnDB/Snyk.
- **Strictly CycloneDX-native.** SPDX SBOM ingestion was *removed* in v4.3
  (#1053); only SPDX license IDs remain; SPDX 3.0 support unimplemented (#1746).
  A blog claiming SPDX import/export was **refuted 0-3**.
- → The realistic OSS single-pane-of-glass, *but* requires a CycloneDX feed; it
  will not eat our SPDX 3.0.1.

### GUAC — provenance graph, not a dashboard
- Ingests **both SPDX and CycloneDX** (+ SLSA, OSV), no version pinned. It's a
  supply-chain graph/provenance aggregator — **complement** to DT, not a
  Black-Duck-style monitoring UI.

### OpenVEX — the lingua franca
- Grype natively consumes OpenVEX via `--vex` (docs from `vexctl`) to move
  `not_affected`/`fixed` findings to ignored. This is the suppression mechanism.

### Yocto-native VEX export (already in tree)
- `vex.bbclass` (`INHERIT += "vex"`, **mutually exclusive with cve-check**)
  generates a VEX manifest from `CVE_STATUS` annotations.
- `CVE_CHECK_VEX_JUSTIFICATION[not-applicable-config] = "vulnerableCodeNotPresent"`
  maps status keywords → standard VEX justifications.
- `SPDX_INCLUDE_VEX` (`none`/`current`/`all`, default `current`) embeds VEX in
  the SPDX 3.0.1 document.
- `yocto-vex-check` (syslinbit) reads cve-check JSON, picks DB at runtime,
  emits **OpenVEX**.

### sbom-cve-check (Bootlin, GPLv2) — we already run this
- Decoupled, out-of-build replacement for cve-check (re-scan without a Yocto
  rebuild). Parses SPDX 2.2/3.0, sources NVD + CVE List, consumes OpenVEX
  (`--yocto-vex-manifest`). Integrated into Yocto 6.0 wrynose; v1.2.0 improved
  SPDX 3.0.

### VulnScout (Savoir-faire Linux) — the aggregation/triage centerpiece
- Ingests **SPDX 2.3 + SPDX 3.0 + CycloneDX 1.4–1.6 + Grype native JSON + Yocto
  cve-check JSON + OpenVEX**. Web triage UI. Exports **OpenVEX / SPDX 3.0 /
  CycloneDX**. Ships `meta-vulnscout` (`inherit vulnscout`,
  `bitbake <image> -c vulnscout`). v0.8.1 fixed OpenVEX+CycloneDX, added SPDX
  3.0 backend.
- This is, in effect, the multi-scanner reconciler + triage UI we would
  otherwise have built. **Maturity at portfolio/fleet scale is unproven** —
  evaluate empirically.

---

## 5. Capabilities and honest limitations

**Where the FOSS stack is strong:**
- **Continuous monitoring** — DT re-analyzes the whole portfolio on new CVEs.
- **VEX-based false-positive suppression** — Grype+OpenVEX + Yocto-native
  export. This is the antidote to scanner false-positive flooding.
- **SPDX-3-native triage** — sbom-cve-check / VulnScout.
- **Auditability** — in-tree `CVE_STATUS[...]` is arguably *better* than a
  DB-side exception list: in git, reviewable, survives turnover.
- **Cost** — zero licensing.

**Honest limitations (state these plainly — it's what makes the case credible):**
- **Curated commercial-grade vuln intelligence.** Top-tier dedup/triage feeds
  (e.g. VulnDB) are paid; the free NVD/GHSA/OSS-Index/OSV mix is credible but
  not equivalent. *(Thinnest claim in the survey — no public benchmark of FOSS
  dedup vs a commercial vuln-intelligence database.)*
- **One dashboard fluent in SPDX 3.0.1.** DT is CycloneDX-only (conversion
  friction); VulnScout covers SPDX but fleet maturity is unproven.
- **Vendor support + accountability** for the audit — inherent to commercial
  offerings; a FOSS stack puts that ownership on you.

---

## 6. The unsolved problem (where to add value)

Yocto→VEX export is **lossy and incomplete**: no VEX format (OpenVEX, CSAF,
CycloneDX) has a justification for key Yocto triage cases — `cpe-incorrect`,
`disputed` (CVE wrong / awaiting upstream), or `abandoned-project-wontfix`.
The override-vs-scanner precedence question is also unresolved. Flagged by the
Yocto vulnerability maintainer in the May-2024 RFC and at FOSDEM 2025.

→ A clean mapping / spec-extension contribution here is genuinely novel upstream
work. So is shipping these pieces as one turnkey reference pipeline (nobody
does).

---

## 7. Open / thin spots (do not present as settled)

- **Gap: SBOM quality scoring** (sbomqs / sbom-utility / quality-bar standards)
  produced no surviving verified claim — uncovered.
- Both sbom-cve-check and VulnScout docs say "SPDX 3.0," not literally "3.0.1
  JSON-LD" — true 3.0.1 fidelity against wrynose output is **inferred**, verify
  empirically.
- `yocto-vex-check` was Feb-2025 / under active development (planned migration
  to YP infra) — repo URL/behavior may have drifted.
- The FOSS-vs-commercial dedup comparison rests on synthesis, not benchmarks.

---

## 8. Sources (primary, verified)

CRA: `digital-strategy.ec.europa.eu/en/policies/cra-reporting` ·
ENISA SRP. Formats/scanners: `trivy.dev/docs/latest/target/sbom/` ·
`github.com/protobom/protobom` · `github.com/CycloneDX/cyclonedx-cli` (#424) ·
`pypi.org/project/lib4sbom` · `oss.anchore.com/docs/guides/sbom/conversion` ·
`security.googleblog.com` (OSV-Scanner v2) · `github.com/iris-GmbH/meta-cyclonedx`.
Monitoring/VEX: `dependencytrack.org` · `owasp.org/www-project-dependency-track`
· `owasp.org/blog/2026/06/09/dependency-track-v5` · `docs.guac.sh/ingesting-sboms`
· `chainguard.dev` (Grype+OpenVEX) · `docs.yoctoproject.org/ref-manual/variables.html`
· `docs.yoctoproject.org/next/security-manual/vulnerabilities.html` ·
FOSDEM-2025 Yocto vuln-mgmt slides · `patchwork.yoctoproject.org/comment/19698`
· `bootlin.com/blog/announcing-sbom-cve-check` · `sbom-cve-check.readthedocs.io`
· `github.com/savoirfairelinux/vulnscout` · `github.com/savoirfairelinux/meta-vulnscout`.

---

## 9. Next step in this repo

Integration spike (see planning notes / commit that follows): wire
`meta-vulnscout` + Yocto VEX export (`SPDX_INCLUDE_VEX` / `vex`) + Grype
`--vex` over a real wrynose build, and measure whether multi-scanner detection
+ VEX suppression yields a clean, deduped, audit-ready view — and where the
lossy-VEX gap (§6) actually bites.
