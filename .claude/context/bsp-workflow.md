# BSP workflow contract

The invariants every skill, agent, and contributor must respect when
touching this repo. Keep this file boring and specific — it is the
spec, not the tutorial.

## Layer ownership

| Layer | Role | Owns |
|---|---|---|
| `meta-edge-distro` | Brand + distro identity | `conf/distro/edge-ai.conf`, packaging defaults, SBOM/CVE wiring, branded psplash, distro-level packagegroups, static uid/gid tables. **Never** machine- or BSP-specific recipes. |
| `meta-edge-bsp` | Board + image scaffolding (multi-machine) | Image recipes (`recipes-core/images/edge-image-*.bb`), board includes (`conf/machine/include/edge-board-<machine>.inc`), board-level systemd presets, and accelerator enablement selected by `EDGE_ACCEL`. Declares **no** vendor-layer dependency: `LAYERDEPENDS` is `core rauc meta-arm openembedded-layer virtualization-layer meta-edge-distro`, and anything targeting a vendor layer lives under `dynamic-layers/<collection>/` so the layer composes for a board with none of it. **Never** distro identity. |
| `meta-renesas` (Renesas vendor BSP, kas-cloned: `meta-rz-bsp` + `meta-rz-distro`) | Machine configs, TF-A, U-Boot, the `linux-renesas` kernel recipe, multimedia kernel modules (mmngr, …). | Composed by `kas/bsp/renesas-rz.yml`, which the machine fragment includes — not by `kas/base.yml`, which is board-neutral. Extended and overridden from `meta-edge-bsp/dynamic-layers/meta-rz-{bsp,distro}/`; never forked. |
| `meta-raspberrypi` (kas-cloned) | Machine conf for `raspberrypi5`, firmware boot files (`rpi-bootfiles`, `rpi-config`), U-Boot defconfig selection. Its vendor kernel recipes are masked. | Composed by `kas/bsp/raspberrypi.yml` from `kas/machines/raspberrypi5.yml`. The kernel (`linux-edge-mainline`, kernel.org stable 6.18), the U-Boot Kconfig fragments and the `u-boot-tools` bbappend live in `meta-edge-bsp/dynamic-layers/raspberrypi/`. |

## Workflow phases

```
Setup --> Customize --> Build --> Sign --> Deploy --> Verify
```

| Phase | What lands |
|---|---|
| **Setup** | KAS composition (`kas/base.yml` + `kas/machines/<board>.yml`, plus opt-in capability fragments). Image tier is the bitbake target, not a kas overlay. Personal `kas/local.yml` for cache paths / parallelism (gitignored). |
| **Customize** | Distro features in `meta-edge-distro/conf/distro/edge-ai.conf`; image recipes in `meta-edge-bsp/recipes-core/images/`; board facts in `meta-edge-bsp/conf/machine/include/edge-board-<machine>.inc`; board DTS / U-Boot patches under `meta-edge-bsp/dynamic-layers/<collection>/`; kernel policy shared by all boards in `meta-edge-bsp/recipes-kernel/linux/edge-kernel-policy.inc`. |
| **Build** | `make base` / `make dev` / `make prod` (wraps `kas shell -c 'bitbake <target>'`), `BOARD=<name>` for a board other than the first. Artifacts under `build/tmp/deploy/images/<machine>/` for the first board, `build/<BOARD>/tmp/deploy/images/<machine>/` for later ones. |
| **Sign** | HSM FIT chain (deferred). Trust profiles planned: `file-keys`, `softhsm`, `yubikey-rot`. Prod image gated to YubiKey ROT only. |
| **Deploy** | RAUC A/B bundle (wired): build `edge-bundle`, `rauc install` to the inactive slot, reboot. WIC image to SD/eMMC for a fresh board. |
| **Verify** | `make parse` (parse gate), boot + `systemctl --failed` (boot gate), RAUC bundle round-trip (OTA gate). |

## Invariants

1. **Public repo, repo-relative paths only.** No absolute `/home/<user>/...` paths, no board IPs, no home-lab topology in any committed file. Operator-local material lives in `kas/local.yml` (gitignored).
2. **Custom distro, not Poky.** `DISTRO=edge-ai` from day one. `kas/base.yml` sets it; do not fall back to `poky`.
3. **Wrynose 6.0 syntax.** `DISTRO_FEATURES_BACKFILL` is gone — use `DISTRO_FEATURES_DEFAULTS` / `DISTRO_FEATURES_OPTED_OUT`. SBOM via `INHERIT += "create-spdx"` (SPDX 3.0). CVE check via `OE_FRAGMENTS += "yocto/sbom-cve-check"` (the legacy `cve-check.bbclass` is gone).
4. **Vendor BSP is machine-selected, not global.** For RZ/V2L, machine configs, kernel (`linux-renesas` → `rz_linux-cip`), U-Boot and TF-A come from `meta-renesas`, composed by `kas/bsp/renesas-rz.yml` from `kas/machines/rzv2l.yml`. Extend/override from `meta-edge-bsp/dynamic-layers/meta-rz-{bsp,distro}/`; never fork the vendor layer. Raspberry Pi 5: `meta-raspberrypi` via `kas/bsp/raspberrypi.yml`, the kernel is this repo's `linux-edge-mainline` under `dynamic-layers/raspberrypi/` (the vendor kernel recipes are masked), U-Boot is oe-core's with Kconfig fragments. A further board adds its own `kas/bsp/<vendor>.yml` and dynamic-layers subtree; `kas/base.yml` is not edited, and `meta-edge-bsp/conf/layer.conf` only gains the `BBFILES_DYNAMIC` line for the new collection.
5. **No silent secure-boot resurrection.** RZ/V2L hardware secure boot (TBBR, OTP, BL2 cert stitching) stays out of scope. U-Boot-level HSM FIT verification is in scope and is the only trust-root layer this repo enforces.
6. **CVE-DB needs network at fetch time.** The wrynose `sbom-cve-check` fragment sets AUTOREV for the NVD / CVEList feeds, but `edge-floor.inc` pins both back to a dated revision, and that pin is what a build fetches. A build host without network access will still fail the first fetch.
7. **DT nodes: validate against primary hardware sources.** Any new device-tree node or peripheral binding must be validated against the SoC hardware manual (register base, interrupts, clocks/resets) **and** an in-tree sibling node before it is trusted — author from the TRM and existing DT, not from inference, memory, or prior context. A node that looks plausible but is wrong fails identically to one that is right-but-unsupported, so a wrong node makes a negative test un-diagnosable. The ISU/VSP enablement (`r01uh0936`, the in-tree G2L sibling) is the cautionary case: register-map validation caught an interrupt off-by-one that would otherwise have shipped as a silent runtime failure.

## Composition (single source of truth)

Composition is `kas/base.yml` + a machine overlay, plus any opt-in
capability fragments, joined by `:`. The image tier is selected by the
bitbake target name, not a kas overlay.

```
kas shell -c 'bitbake edge-image-base' kas/base.yml:kas/machines/rzv2l.yml
kas shell -c 'bitbake edge-image-base' kas/base.yml:kas/machines/raspberrypi5.yml
```

There is no canonical "rzv2l.yml" entry point. Composition explicit,
layout uniform across boards.
