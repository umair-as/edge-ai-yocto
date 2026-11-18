# Vulnerability-management tooling — landscape

A factual survey of the FOSS tools relevant to vulnerability management on a
Yocto distro, and the one constraint that shapes the pipeline: SPDX 3.0.1
ingestion. Tools and format support are verified against upstream docs as of
2026-07; the ecosystem moves fast, so re-check version-pinned claims before
relying on them.

Companion to [`cve-triage.md`](cve-triage.md), [`sbom-analysis.md`](sbom-analysis.md),
and [`security-baseline.md`](security-baseline.md). The pipeline this repo actually
runs is in [`vuln-mgmt-architecture.md`](vuln-mgmt-architecture.md).

## SPDX 3.0.1 ingestion — the constraint that shapes the pipeline

wrynose emits SPDX **3.0.1**, but **no production vulnerability scanner ingests
SPDX 3.0.1 JSON-LD.** Trivy, Grype, and OSV-Scanner accept SPDX 2.x and
CycloneDX only. On the SBOM-tool side this began shifting in late June 2026 —
syft v1.46.0 (2026-06-26) added SPDX 3 read/write and lib4sbom parses SPDX 3
JSON-LD — but these are generators/libraries, not scanners, and target an SPDX 3
release candidate, so a clean "3.0.1" claim is unconfirmed. Converters are also
immature: `protobom` (v0.5.8) tops out at SPDX 2.3, and `cyclonedx-cli`'s
SPDX→CycloneDX conversion drops PURLs (issue #424, open).

Consequence: scanners are fed the extracted **rootfs** (`grype dir:`), or a
natively-generated CycloneDX (`meta-cyclonedx`, CDX 1.6/1.7) — never a converted
SPDX 3.0.1.

## The tools

### In this repo's pipeline

- **sbom-cve-check** (GPL-2.0, v1.3.2) — the CVE engine wrynose ships. Re-scans
  an existing SBOM without a rebuild, parses SPDX 2.2/3.0, sources NVD + CVE
  List, consumes OpenVEX (`--yocto-vex-manifest`).
- **[yocto-security-tools](https://github.com/Ericsson/yocto-security-tools)**
  (Ericsson, FOSS) — CVE remediation tooling:
  `cve_metadata_extractor` (aggregates NVD/OSV/Debian/Ubuntu fix data per
  finding), `cve_corrector` (batch backport attempts from distro patch
  series), `cve_agent` (LLM-assisted conflict resolution). Used here as a
  *proposal* layer only: its output — backport patches and suggested
  dispositions — lands only after per-claim review
  ([`cve-triage.md`](cve-triage.md) rule 7,
  [`vuln-mgmt-architecture.md`](vuln-mgmt-architecture.md) D4).
  A review of six exit-12 "vulnerable code absent" results found that none was
  valid evidence for a disposition; every claim requires independent per-claim
  verification against upstream material and shipped code.
- **Grype** with `--vex` — consumes OpenVEX and moves `not_affected` / `fixed`
  findings to ignored (`--fail-on` overrides `--vex`). The only third-party
  scanner in use, run over the rootfs for breadth.
- **Yocto-native VEX** — `vex.bbclass` (`INHERIT += "vex"`) writes VEX *input*
  from `CVE_STATUS` (not a finished OpenVEX manifest — sbom-cve-check produces
  that); `CVE_CHECK_VEX_JUSTIFICATION[...]` maps status keywords to VEX
  justifications; `SPDX_INCLUDE_VEX` (default `current`; this distro sets
  `all` — see [`vex-and-cve-status.md`](vex-and-cve-status.md)) embeds VEX in
  the SPDX document. The standalone `yocto-vex-check` tool is defunct (repo withdrawn).

### Surveyed, not used

- **Dependency-Track 5.0** (Apache-2.0, GA 2026-06-09) — a portfolio dashboard,
  strictly CycloneDX-native: SPDX ingestion was removed in v4.3 (#1053) and SPDX
  3.0 is on-hold (#1746). Would require a CycloneDX feed.
- **VulnScout** (Savoir-faire Linux, v0.17.1) + `meta-vulnscout` — a multi-format
  triage UI that ingests cve-check JSON, Grype JSON, SPDX 2.3/3.0, CycloneDX and
  OpenVEX, and exports OpenVEX / SPDX / CycloneDX. Fleet-scale maturity unproven.
- **GUAC** (OpenSSF incubating, v1.1.0) — a supply-chain provenance graph
  (SPDX / CycloneDX / SLSA / OSV / OpenVEX), not a monitoring dashboard.
- **OSV-Scanner v2**, **meta-cyclonedx**, **sbomqs / sbom-utility** — additional
  breadth, native CycloneDX generation, and SBOM quality scoring respectively;
  the last's SPDX 3.0.1 support is unverified.

## Known gaps

- **Yocto→VEX export is lossy.** No VEX format (OpenVEX, CSAF, CycloneDX VEX)
  carries a justification for `cpe-incorrect`, `disputed`, or
  `abandoned-project-wontfix`, and override-vs-scanner precedence is unresolved.
  Raised by the Yocto vulnerability maintainer (May-2024 RFC, FOSDEM 2025).
- **SPDX 3.0.1 fidelity is inferred** — sbom-cve-check and VulnScout docs say
  "SPDX 3.0," not "3.0.1"; verify against wrynose output before relying on it.
- **FOSS vs commercial vulnerability intelligence** is not benchmarked here;
  curated commercial feeds (VulnDB) are paid, and the free NVD/GHSA/OSV mix is
  not proven equivalent.

## Sources

- **Formats & scanners** — `trivy.dev/docs`; `oss.anchore.com` (Grype, syft);
  `github.com/anchore/syft` (PR #4269); `github.com/protobom/protobom`;
  `github.com/CycloneDX/cyclonedx-cli` (#424); `pypi.org/project/lib4sbom`;
  `github.com/google/osv-scanner`; `github.com/iris-GmbH/meta-cyclonedx`.
- **Aggregation / VEX / monitoring** — `dependencytrack.org` +
  `github.com/DependencyTrack` (#1053, #1746); `docs.guac.sh`;
  `github.com/savoirfairelinux/{vulnscout,meta-vulnscout}`.
- **Yocto vulnerability handling** — `bootlin.com/blog` +
  `github.com/bootlin/sbom-cve-check`;
  `github.com/Ericsson/yocto-security-tools`;
  `docs.yoctoproject.org/next/security-manual/vulnerabilities.html`;
  FOSDEM-2025 Yocto vuln-mgmt slides.
