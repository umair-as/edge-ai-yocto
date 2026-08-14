# SBOM analysis

The `sbom-cve-check` class (wrynose) emits an SBOM per image into
`build/tmp/deploy/images/<machine>/`:

| File | Format | Contents |
|---|---|---|
| `*.sbom-cve-check.spdx.json` | SPDX **3.0.1** JSON-LD `@graph` | typed package / license / vulnerability nodes joined by `spdxId` |

`scripts/sbom-report.py` reads it. It is read-only over the deploy tree —
it produces no build state and runs against any completed image without a
rebuild. This is inventory and license analysis, not vulnerability triage;
CVEs are handled separately in [`cve-triage.md`](cve-triage.md).

```sh
scripts/sbom-report.py           # newest SBOM — inventory summary
scripts/sbom-report.py -i <path> # a specific SBOM
```

## Format note (scarthgap → wrynose)

The SBOM changed model entirely. SPDX 2.2's flat `packages[]` array — with
inline `versionInfo` / `licenseDeclared` / `downloadLocation` — became SPDX
3.0.1, a JSON-LD `@graph` of typed nodes (`software_Package`,
`simplelicensing_LicenseExpression`, `security_Vulnerability`, VEX
relationships). License attaches through a `hasDeclaredLicense` relationship
whose `from` is often a source or file node, so the script joins package to
license on the per-recipe document segment of the `spdxId`, not on a direct
field.

## Inventory summary

```sh
scripts/sbom-report.py [-i FILE] [--top N] [--all] [--csv OUT]
```

The summary reports the inventory split by SPDX `software_primaryPurpose` —
recipes (`specification`), installed packages (`install`), and fetched source
artifacts (`source`) — plus a license-category breakdown, the top license
expressions, and a HIGH-risk review list. `--csv` writes a package / version /
license / category / risk / download-location / package-URL / homepage table for
supply-chain traceability.

Download-URL coverage is measured over `source` nodes only: those are the
fetched upstream artifacts (crates, tarballs, git), and each carries its URL.
Built packages (`install` / `specification`) have no download URL by design —
the URL lives on the related `source` node — so they are not counted as a gap.

License classification operates on the expression string only
(format-independent) and is tuned for an embedded image:

| Category | Risk | Examples |
|---|---|---|
| `proprietary` | HIGH | `LicenseRef-Proprietary`, commercial markers — verify distribution rights |
| `copyleft-strong` | HIGH | v3 / AGPL / LGPL-3.0 — installation-information (anti-tivoization) and network clauses |
| `copyleft-weak` | MEDIUM | GPL-2.0, LGPL-2.x, MPL, EPL — informational; GPL-2.0 is the kernel license and ubiquitous |
| `permissive` | LOW | MIT, BSD, Apache-2.0, ISC, Zlib |
| `public_domain` | LOW | CC0, 0BSD, Unlicense |
| `custom` / `unknown` | MEDIUM | `LicenseRef-*`, NOASSERTION |

Only HIGH-risk expressions are listed for review; GPL-2.0 is deliberately
not surfaced as a concern. The classifier operates purely on the expression
text, so it is unaffected by the 2.2 → 3.0.1 document-model change.

A note on precision: a `0BSD`/`CC0` package classifies as `permissive`
rather than `public_domain` when its expression also carries a BSD token,
and a recipe declaring several license expressions is categorised by the
first — both LOW-risk cases that do not affect the HIGH-risk review list.
