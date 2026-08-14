# meta-edge-distro

Distro policy and brand identity for EDGE AI OS. This layer defines the
`edge-ai` distro, baseline distro features, SBOM and CVE policy, package
format defaults, image profile includes, and project-owned branding such as
psplash assets.

## Dependencies

| Layer collection | Purpose |
|------------------|---------|
| `core` | OpenEmbedded-Core recipes, classes, and distro infrastructure |

## Maintainer

Umair Ashraf <https://github.com/umair-as>

## License

Layer metadata, recipes, and project-owned files are MIT licensed unless a
file says otherwise. Upstream source fetched by recipes keeps its original
license.

## Contributing

Submit patches through the project pull-request flow. Recipe patches must
carry a valid `Upstream-Status` tag using the OpenEmbedded taxonomy, such as
`Pending`, `Submitted`, `Backport`, `Denied`, or `Inappropriate`, with enough
context for future refreshes.
