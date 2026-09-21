# meta-edge-bsp

Board support, image scaffolding, and board-level integration for
EDGE AI OS. This layer carries the image recipes for the RZ/V2L SMARC EVK and
the Raspberry Pi 5, per-board facts, machine-gated BSP patches, RAUC helper
configuration, OP-TEE integration, boot assets, and runtime hardening
packages that belong below the distro policy layer.

## Dependencies

Required by every composition:

| Layer collection | Purpose |
|------------------|---------|
| `core` | OpenEmbedded-Core recipes and classes |
| `openembedded-layer` | Recipes extended by the kernel-tooling appends (`bpftool`) |
| `rauc` | RAUC recipes extended by the OTA configuration |
| `meta-arm` | OP-TEE and Trusted Firmware-A recipes |
| `virtualization-layer` | Container userspace, baseline on every image tier |
| `meta-edge-distro` | `edge-ab-image` and the classes the image recipes inherit |

Selected by the machine fragment and parsed through `BBFILES_DYNAMIC` only
when the collection is composed, so a board without a vendor layer does not
carry a dangling append:

| Layer collection | Purpose |
|------------------|---------|
| `meta-rz-bsp` | Renesas RZ machine support and vendor BSP recipes |
| `meta-rz-distro` | Renesas RZ multimedia userspace recipes extended for the image tiers |
| `raspberrypi` | Raspberry Pi 5 machine configuration and firmware boot files |
| `meta-deepx-m1` | DEEPX DX-M1 runtime, driver and service glue |

## Maintainer

Umair Ahmed Shah <https://github.com/umair-as>

## License

Layer metadata, recipes, and project-owned files are MIT licensed unless a
file says otherwise. Upstream firmware and third-party source fetched by
recipes keep their original licenses.

## Contributing

Submit patches through the project pull-request flow. Recipe patches must
carry a valid `Upstream-Status` tag using the OpenEmbedded taxonomy, such as
`Pending`, `Submitted`, `Backport`, `Denied`, or `Inappropriate`, with enough
context for future refreshes.
