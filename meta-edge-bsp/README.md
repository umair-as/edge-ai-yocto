# meta-edge-bsp

Board support, image scaffolding, and board-level integration for
EDGE AI OS. This layer carries the RZ/V2L SMARC EVK image recipes,
machine-gated BSP patches, RAUC helper configuration, OP-TEE integration,
boot assets, and runtime hardening packages that belong below the distro
policy layer.

## Dependencies

| Layer collection | Purpose |
|------------------|---------|
| `core` | OpenEmbedded-Core recipes and classes |
| `meta-rz-bsp` | Renesas RZ machine support and vendor BSP recipes |
| `meta-rz-distro` | Renesas RZ multimedia userspace recipes extended for the image tiers |
| `rauc` | RAUC recipes extended by the OTA configuration |
| `meta-arm` | OP-TEE and Trusted Firmware-A recipes extended for RZ/V2L |

The optional `virtualization-layer` collection is used through
`BBFILES_DYNAMIC`; its bbappends are parsed only when that layer is present.

## Maintainer

Umair Ashraf <https://github.com/umair-as>

## License

Layer metadata, recipes, and project-owned files are MIT licensed unless a
file says otherwise. Upstream firmware and third-party source fetched by
recipes keep their original licenses.

## Contributing

Submit patches through the project pull-request flow. Recipe patches must
carry a valid `Upstream-Status` tag using the OpenEmbedded taxonomy, such as
`Pending`, `Submitted`, `Backport`, `Denied`, or `Inappropriate`, with enough
context for future refreshes.
