# BSP workflow contract

The invariants every skill, agent, and contributor must respect when
touching this repo. Keep this file boring and specific — it is the
spec, not the tutorial.

## Layer ownership

| Layer | Role | Owns |
|---|---|---|
| `meta-edge-distro` | Brand + distro identity | `conf/distro/edge-ai.conf`, packaging defaults, SBOM/CVE wiring, branded psplash, distro-level packagegroups, static uid/gid tables. **Never** machine- or BSP-specific recipes. |
| `meta-edge-bsp` | Board + image scaffolding (multi-machine-ready) | Image recipes (`recipes-core/images/edge-image-*.bb`), board patches (kernel DTS, U-Boot/TF-A deltas), board-level systemd presets, and feature-gated stacks such as the DRP-AI enablement (gated by `EDGE_ENABLE_AI`). **Never** distro identity. |
| `meta-renesas` (Renesas vendor BSP, kas-cloned: `meta-rz-bsp` + `meta-rz-distro`) | Machine configs, TF-A, U-Boot, the `linux-renesas` kernel recipe, multimedia kernel modules (mmngr, …). | We extend and override via `meta-edge-bsp`, never fork. |

## Workflow phases

```
Setup --> Customize --> Build --> Sign --> Deploy --> Verify
```

| Phase | What lands |
|---|---|
| **Setup** | KAS composition (`kas/base.yml` + `kas/machines/<board>.yml`, plus opt-in capability fragments). Image tier is the bitbake target, not a kas overlay. Personal `kas/local.yml` for cache paths / parallelism (gitignored). |
| **Customize** | Distro features in `meta-edge-distro/conf/distro/edge-ai.conf`; image recipes in `meta-edge-bsp/recipes-core/images/`; board DTS / U-Boot patches in `meta-edge-bsp/recipes-{kernel,bsp}/`. |
| **Build** | `make base` / `make dev` / `make prod` (wraps `kas shell -c 'bitbake <target>'`). Artifacts under `build/tmp/deploy/images/<machine>/`. |
| **Sign** | HSM FIT chain (deferred). Trust profiles planned: `file-keys`, `softhsm`, `yubikey-rot`. Prod image gated to YubiKey ROT only. |
| **Deploy** | RAUC A/B bundle (wired): build `edge-bundle`, `rauc install` to the inactive slot, reboot. WIC image to SD/eMMC for a fresh board. |
| **Verify** | `make parse` (parse gate), boot + `systemctl --failed` (boot gate), RAUC bundle round-trip (OTA gate). |

## Invariants

1. **Public repo, repo-relative paths only.** No absolute `/home/<user>/...` paths, no board IPs, no home-lab topology in any committed file. Operator-local material lives in `kas/local.yml` (gitignored).
2. **Custom distro, not Poky.** `DISTRO=edge-ai` from day one. `kas/base.yml` sets it; do not fall back to `poky`.
3. **Wrynose 6.0 syntax.** `DISTRO_FEATURES_BACKFILL` is gone — use `DISTRO_FEATURES_DEFAULTS` / `DISTRO_FEATURES_OPTED_OUT`. SBOM via `INHERIT += "create-spdx"` (SPDX 3.0). CVE check via `OE_FRAGMENTS += "yocto/sbom-cve-check"` (the legacy `cve-check.bbclass` is gone).
4. **Renesas vendor BSP.** Machine configs, kernel (`linux-renesas` → `rz_linux-cip`), U-Boot, and TF-A come from `meta-renesas` (`meta-rz-bsp` + `meta-rz-distro`). Extend/override in `meta-edge-bsp`; never fork the vendor layer.
5. **No silent secure-boot resurrection.** RZ/V2L hardware secure boot (TBBR, OTP, BL2 cert stitching) stays out of scope. U-Boot-level HSM FIT verification is in scope and is the only trust-root layer this repo enforces.
6. **CVE-DB needs network at fetch time.** The wrynose `sbom-cve-check` fragment uses AUTOREV for the NVD / CVEList feeds — a build host without network access will fail to fetch.

## Composition (single source of truth)

Composition is `kas/base.yml` + a machine overlay, plus any opt-in
capability fragments, joined by `:`. The image tier is selected by the
bitbake target name, not a kas overlay.

```
kas shell -c 'bitbake edge-image-base' kas/base.yml:kas/machines/rzv2l.yml
```

There is no canonical "rzv2l.yml" entry point. Composition explicit,
layout uniform across boards.
