<div align="center">

# edge-ai-yocto

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Yocto](https://img.shields.io/badge/Yocto-Wrynose%206.0-orange.svg)](https://www.yoctoproject.org/)
[![Platform](https://img.shields.io/badge/platform-Renesas%20RZ%2FV2L-blue.svg)](https://www.renesas.com/en/products/microcontrollers-microprocessors/rz-mpus/rzv2l)
[![RAUC](https://img.shields.io/badge/OTA-RAUC-green.svg)](https://rauc.io/)

</div>

**EDGE AI OS** is a hardened, container-native edge-AI Linux platform built on Yocto 6.0 (wrynose), with the Renesas RZ/V2L SMARC EVK as the first board and the Raspberry Pi 5 as the second. It connects a measured boot chain — TF-A → OP-TEE → U-Boot → FIT-signed kernel on RZ/V2L, firmware → U-Boot → FIT-signed kernel on the Pi — to rootless-container NPU inference, wires RAUC A/B over-the-air updates with signed, encrypted-by-default bundles, and treats the whole system as a security product rather than a vendor demo kit. The board-agnostic architecture makes RZ/V2L the first target, not the only one.

---

## What makes it notable

- 🧠 **Container-native NPU inference, on both boards.** Each board's neural accelerator runs inside a rootless Podman container under a dedicated system principal — no root, no capability widening, a per-principal subuid namespace. Validated on hardware: RZ/V2L DRP-AI at 27 ms/frame (ResNet18); Raspberry Pi 5 DX-M1 at 271.88 FPS (YOLOv5S 640×640, benchmark mode) through a rootless Quadlet reaching the host's accelerator daemon over a bind-mounted IPC socket. The model-as-OCI-artifact direction is already scoped into the runtime packaging.

- 🔒 **Signed boot chain, end to end.** TF-A (Renesas CIP fork) → OP-TEE (secure world, BL32) → U-Boot → FIT image with RSA-2048 signature verified against a key embedded in the U-Boot control DTB. A file key covers the dev profile; the signing slot is designed for HSM/YubiKey-ROT in production.

- 🔄 **RAUC A/B OTA with automatic rollback.** Signed, encrypted-by-default (RAUC crypt format) bundles, atomic install, U-Boot boot-count fallback. Kernel/DTB and rootfs update paths both validated on hardware, as is mTLS HTTPS streaming install — a 253 MB bundle streamed from the update server straight into the inactive slot, with no local copy and the transfer running as an unprivileged user.

- 🧱 **Board-agnostic from the first commit.** A second SoC joins the build with a kas BSP fragment and a machine fragment, a board-facts include, one WKS file, and vendor-gated bbappends under `dynamic-layers/` — distro, image recipes, and hardening are untouched. Exercised, not asserted: the Raspberry Pi 5 is composed exactly this way, on a mainline-stable 6.18 kernel and a GPT layout, with U-Boot configured by Kconfig fragments alone.

- 📋 **SBOM + CVE scanning in the default build.** SPDX 3.0.1 generated for every image; NVD and CVE-list scanning wired in. No opt-in; it's part of the baseline, not an afterthought.

---

## Status

Hardware-validated on RZ/V2L SMARC EVK: full boot chain, A/B OTA round-trip, rootless DRP-AI container inference. Raspberry Pi 5 (second board) with the DEEPX DX-M1 PCIe accelerator: signed A/B boot, RAUC install and slot switch, and rootless DX-M1 container inference — all validated on hardware, the last auto-starting from the shipped Quadlet at boot. In progress: DM-VERITY rootfs enforcement, IMA appraisal, HSM/YubiKey signing, and the production image tier.

---

## Quick start

```bash
# 1. Provide operator credentials (never committed)
cp kas/local.yml.example kas/local.yml
$EDITOR kas/local.yml          # set EDGE_DEFAULT_PASSWORD_HASH (openssl passwd -6)

# 2. Generate the dev RAUC PKI (required: bundle encryption is on by default)
./scripts/rauc-init-certs.sh

# 3. Build
make base                      # edge-image-base  (~1–3 h cold cache; fast on warm sstate)
make dev                       # edge-image-dev — adds shell tools, OP-TEE userspace

# 4. Flash
sudo bmaptool copy \
  build/tmp/deploy/images/smarc-rzv2l/edge-image-base-smarc-rzv2l.wic.zst \
  /dev/sdX
```

`make` sets up the kas environment automatically — no manual shell sourcing needed.
Use `make shell` for an interactive kas shell; `make help` lists all targets and
capability flags (`TPM=1`, `SBOM_TUNE=1`, …).

---

## Where to go next

- **[AGENTS.md](AGENTS.md)** — build commands, kas composition, layer conventions, and contributing rules
- **[docs/security/README.md](docs/security/README.md)** — security posture overview and on-board verification commands
- **[docs/drp-ai/README.md](docs/drp-ai/README.md)** — DRP-AI integration overview and model-compile guide
- **[docs/dxm1/README.md](docs/dxm1/README.md)** — DX-M1 integration overview and proof

---

**Hardware:** Renesas RZ/V2L SMARC EVK (dual Cortex-A55 + DRP-AI accelerator); Raspberry Pi 5 (quad Cortex-A76, PCIe accelerator slot) as the second board.
**License:** MIT (recipes and configuration in this repo). Upstream firmware (TF-A, U-Boot, OP-TEE) carries its respective BSD/GPL license.

*Reference implementation — not certified, not for fleet deployment as-is.*
