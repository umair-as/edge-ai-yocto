# CRA vuln-mgmt integration spike — findings

Evidence log for the multi-scanner + OpenVEX pipeline spike (see
[`foss-cra-tooling-survey.md`](foss-cra-tooling-survey.md) for the architecture
this validates). Each stage records real numbers from a concrete build, plus a
go/no-go. Re-runnable: scanner pins live in
[`scripts/install-scanners.sh`](../../scripts/install-scanners.sh); analysis is
[`scripts/sbom-cve-report.py`](../../scripts/sbom-cve-report.py) and
[`scripts/cve-reconcile.py`](../../scripts/cve-reconcile.py).

**Build under test:** `edge-image-dev`, `smarc-rzv2l`, rootfs
`20260619121531`. SBOM/CVE engine: `sbom-cve-check` (Bootlin) with pinned
NVD/CVElist SRCREVs.

---

## Stage 0 — baseline (no build)

`sbom-cve-check` over the build, via `sbom-cve-report.py`.

| Status | Count |
|---|---|
| Patched | 16,575 |
| Ignored | 886 |
| **Unpatched** | **482** |
| Total evaluated | 17,943 |

Unpatched 482 = **397 kernel (`linux-renesas`) / 85 userland**. Severity:
1 CRITICAL · 82 HIGH · 186 MEDIUM · 25 LOW · 188 NO_SCORE.

SBOM (SPDX 3.0.1): 3,698 packages · 479 recipes · 222 licenses · 289
copyleft-strong expressions · 1,589 packages w/o download URL.

**VEX already embedded.** The `sbom-cve-check.spdx.json` carries a complete VEX
spine — 482 `VexAffected` (= Unpatched) + 16,597 `VexFixed` + 912
`VexNotAffected`. The build-time `create-spdx` `spdx.json` carries only a
partial set (54 + 57), consistent with `SPDX_INCLUDE_VEX` being unset. **But**
no production scanner ingests SPDX 3.0.1 JSON-LD (survey §2), so this VEX is not
directly consumable — Stage 2 (`yocto-vex-check` → OpenVEX) is still required.

**Two structural facts found at baseline:**

1. **The in-tree `CVE_STATUS[...]` surface is empty.** Zero `CVE_STATUS` in
   `meta-edge-bsp`/`meta-edge-distro`; no `edge-cve-ignores.inc` yet. All 886
   Ignored are inherited from upstream layers (oe-core, meta-renesas). The
   "in-tree decisions drive suppression" mechanism has no in-tree decisions
   behind it yet — the spike validates the mechanism, then we populate it.
2. **Lossy-VEX preview** — the 886 Ignored by reason: `not-applicable-config`
   863 and `not-applicable-platform` 4 map cleanly to OpenVEX justifications;
   **`disputed` 11 + `cpe-incorrect` 4 + `upstream-wontfix` 3 = ~18** have no
   standard VEX justification (survey §6). Stage 2 confirms the surviving count.

**Go/No-Go: GO.**

---

## Stage 1 — breadth: Grype delta (no build)

Question: which CVEs does Grype surface that `sbom-cve-check` did **not**,
reconciled by package+CVE identity — not raw totals.

**Method.** Grype `0.114.0`, vuln DB schema `v6.1.7` built `2026-06-19`,
installed pinned into `.tooling/bin`. Scanned the extracted rootfs
(`grype dir:`); rootfs ships an RPM database + 1,850 Python artifacts.
Reconciled against the same build's `sbom-cve-check.yocto.json` by
`cve-reconcile.py`: Grype's installed-package identity (PURL/CPE) is normalized
to the Yocto recipe name (RPM `sourceRpm`/`upstreams` → recipe PN; Go `stdlib` →
`go-runtime`; Go module path → trailing segments), then each (recipe, CVE) is
classified.

### Headline reconciliation

| Bucket | Count | Meaning |
|---|---|---|
| overlap | **0** | Grype CVEs also in sbom-cve-check |
| **new** | **14** | recipe IS tracked, but the CVE was missed |
| irreconcilable-identity | **34** | Grype package maps to no recipe — reported separately, **not** counted as new |
| non-CVE (GHSA/other only) | 0 | — |
| **distinct CVE ids from Grype** | **47** | of which **0** appear anywhere in sbom-cve-check |

**All 47 distinct CVEs Grype flags are absent from sbom-cve-check, and all 212
matches are `go-module`** — the Go dependency layer. New findings by severity:
7 HIGH + 7 MEDIUM (all userland, all `go-runtime`/stdlib; no kernel, no
Critical). The 34 irreconcilable include **10 Critical**.

### What the delta actually is (two distinct mechanisms)

- **34 irreconcilable = vendored Go modules with no backing recipe** —
  `golang.org/x/crypto` (8, incl. 7 Critical), `github.com/docker/docker` (5),
  `github.com/moby/buildkit` (2, 1 Critical), `golang.org/x/net`, `grpc`,
  `sigstore/fulcio`, `otel`. The container stack is **podman**-based; these are
  vendored *inside* podman's Go binaries. **`sbom-cve-check` cannot see them by
  construction** — there is no recipe named `golang.org/x/crypto` to CPE-match.
  This is the clean, DB-date-independent breadth argument: recipe→CPE scanning
  is structurally blind to the vendored-dependency layer.
- **14 new = `go-runtime` stdlib CVEs** — `go-runtime` *is* a tracked recipe
  (171 issues, 5 from 2026, all Patched), but none of these 14 (all
  `CVE-2026-*`, recently assigned) are among them. **Confounded by DB
  freshness:** Grype's DB is `2026-06-19`; sbom-cve-check ran against pinned
  NVD/CVElist SRCREVs. Grype's Go source (Go vuln DB / GHSA) also tracks stdlib
  CVEs by Go version directly, ahead of NVD CPE assignment. Cannot cleanly
  separate "fresher DB" from "better Go source" offline.

### Caveats (load-bearing — do not drop)

- **Not a head-to-head on OS packages.** os-release `ID=edge-ai` is unknown to
  Grype → distro detection failed → Grype's RPM/OS-package matchers were
  **disabled**. The 1,112 RPM packages were cataloged but **not** vuln-matched.
  Grype's contribution here is *only* the Go layer. OS-package parity needs a
  `grype --distro` re-run (Stage 1.5 follow-up, not done).
- **DB-date skew** affects the 14 `go-runtime` findings (above). A fair
  de-confound: re-run sbom-cve-check with AUTOREV CVE-DB, or pin Grype's DB to
  the build date.

### Verdict

Grype's breadth is **real and worth carrying** — but the irrefutable value is
**visibility into the vendored Go-dependency layer** (34 findings, 10 Critical,
structurally invisible to recipe→CPE scanning), not raw OS-package overlap
(untested here). The go-runtime delta is suggestive but DB-date-confounded.

**Go/No-Go: GO to carry Grype**, conditional on a `--distro` re-run to establish
OS-package behaviour before drawing OS-layer conclusions.

*(Decision pending operator review — does this breadth justify carrying Grype,
and do we want the `--distro` re-run / Trivy+OSV comparison next?)*

---

## Finding: the CVE_STATUS propagation gap (worked example — CVE-2024-12084)

A full triage of a single finding surfaced a distinct gap class — *not* the
lossy-justification gap of §6. Recorded because it changes where the pipeline
adds value.

**The CVE.** CVE-2024-12084 — heap overflow in the rsync **daemon**
(attacker-controlled `s2length`), CVSS 9.8. Affected `>= 3.2.7, < 3.4.0`; fixed
upstream in **3.4.0** (CERT VU#952657, oss-security 2025-01-14). This image
builds rsync **3.4.1**, which carries the fix. Verified on the running target:
3.4.1 installed, no `rsync`/`rsyncd` unit, daemon not running, nothing bound to
TCP/873. **Not affected** — two independent grounds (fixed version + the
daemon-only vulnerable path is never started).

**The accurate decision** (`meta-edge-bsp/recipes-devtools/rsync/rsync_%.bbappend`):

```bitbake
CVE_STATUS[CVE-2024-12084] = "fixed-version: fixed upstream in rsync 3.4.0, recipe builds 3.4.1"
```

`fixed-version` maps to Patched (`cve-check-map.conf`). The flag verifiably
resolves in rsync's datastore
(`bitbake-getvar -r rsync --flag CVE-2024-12084 --value CVE_STATUS`). Yet after
regenerating the SBOM, the CVE stayed **Unpatched / version-maybe-in-range** —
the count did not move.

**Mechanism (traced):**

```
CVE_STATUS=fixed-version  → create-spdx marks the CVE "fixed"
                          → SPDX_INCLUDE_VEX="current" (default) excludes
                            already-fixed CVEs from the emitted VEX
                          → rsync's per-recipe SPDX carries no assertion for the
                            CVE (0 nodes in any rsync spdx doc)
                          → Bootlin sbom-cve-check re-scans NVD independently
                          → ambiguous NVD data (discrete affected versions, no
                            fixed boundary) → "version-maybe-in-range"
                          → re-flagged Unpatched / VexAffected
```

The tool derives "Patched" from its **own** version comparison, never from a
`fixed-version` VEX. So `fixed-version` only registers when the scanner already
agrees the version is fixed; on an ambiguous NVD range it cannot, and the
decision evaporates in transit. (Contrast: the not-affected-family statuses —
`not-applicable-config` etc. — stay in "current" VEX as `VexNotAffected` and
*are* honored. That is why the 886 inherited suppressions show up and this one
does not.)

**Two distinct gap classes — do not conflate:**

| | Vocabulary gap (§6) | Propagation gap (this) |
|---|---|---|
| What | No VEX justification exists for the status | Status maps cleanly but doesn't survive transit |
| Cases | `disputed`, `cpe-incorrect`, `abandoned-project` (~18) | `fixed-version` under `SPDX_INCLUDE_VEX=current` |
| Fix locus | OpenVEX/CSAF spec extension (upstream) | Pipeline wiring (emit `VexFixed`, or consume VEX in a downstream tool) |

**The sharper tension.** The *truest* status (`fixed-version`) fails to
propagate. The statuses that *do* propagate (the not-affected family) don't
precisely fit: rsync's daemon code is **compiled into the binary but never run
as a service** — VEX justification `vulnerableCodeNotInExecutePath`. Yocto's
`CVE_STATUS` vocabulary has **no clean slot** for "present-but-unreachable"; the
closest tool-honored statuses (`not-applicable-config`, `cpe-incorrect`) are
each a misstatement of why the box is not exposed.

**Decision (recorded):**

- **Keep `fixed-version`** — truth over cosmetics. rsync 3.4.1 contains the fix;
  that is the accurate status, and the bbappend annotation records both grounds.
- **Reject** switching to a tool-honored-but-inaccurate status
  (`cpe-incorrect`/`ignored`) merely to make the count flip. The report is not
  gamed with a false justification.
- **Demonstrate real suppression at Stage 2** via OpenVEX → `grype --vex`, the
  pipeline's designed VEX-consumption path. The sbom-cve-check report's residual
  `version-maybe-in-range` is documented as a known-conservative artifact of
  ambiguous NVD data, not an unresolved exposure.

**Implication for the spike.** In-tree `CVE_STATUS` decisions are auditable and
correct, but their *visibility in the sbom-cve-check report* is
mechanism-limited. Multi-tool + OpenVEX (Stage 2/3) is not only breadth — it is
the layer where a cleanly-mapped decision like this one actually suppresses.

---

## Next stages

Stage 2 (OpenVEX spine via `yocto-vex-check` → `grype --vex` suppression) and
Stage 3 (aggregate / VulnScout) are scoped but not yet executed; see the OPEN
items in [`vuln-mgmt-architecture.md`](vuln-mgmt-architecture.md).
