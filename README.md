<div align="center">

# edge-ai-yocto

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Yocto](https://img.shields.io/badge/Yocto-Wrynose%206.0-orange.svg)](https://www.yoctoproject.org/)
[![RZ/V2L](https://img.shields.io/badge/board-Renesas%20RZ%2FV2L-blue.svg)](https://www.renesas.com/en/products/microcontrollers-microprocessors/rz-mpus/rzv2l)
[![Raspberry Pi 5](https://img.shields.io/badge/board-Raspberry%20Pi%205-blue.svg)](https://www.raspberrypi.com/products/raspberry-pi-5/)
[![VENTUNO Q](https://img.shields.io/badge/board-Arduino%20VENTUNO%20Q-blue.svg)](docs/dev/emmc/ventuno-q.md)
[![RAUC](https://img.shields.io/badge/OTA-RAUC-green.svg)](https://rauc.io/)
[![Repo lint](https://github.com/umair-as/edge-ai-yocto/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/umair-as/edge-ai-yocto/actions/workflows/lint.yml)
[![Kernel hardening](https://github.com/umair-as/edge-ai-yocto/actions/workflows/kernel-hardening.yml/badge.svg?branch=main)](https://github.com/umair-as/edge-ai-yocto/actions/workflows/kernel-hardening.yml)
[![Yocto check](https://github.com/umair-as/edge-ai-yocto/actions/workflows/yocto.yml/badge.svg)](https://github.com/umair-as/edge-ai-yocto/actions/workflows/yocto.yml)

</div>

**EDGE AI OS** is a hardened, container-native edge-AI Linux platform built on Yocto 6.0 (wrynose) for three boards: the Renesas RZ/V2L SMARC EVK, the Raspberry Pi 5 and the Arduino VENTUNO Q (Qualcomm QCS8275). It connects a verified boot chain — TF-A → OP-TEE → U-Boot → FIT-signed kernel on RZ/V2L, firmware → U-Boot → FIT-signed kernel on the Pi, Qualcomm firmware → UEFI → systemd-boot → one kernel image per slot on the VENTUNO Q — to rootless-container NPU inference, wires RAUC A/B over-the-air updates with signed, encrypted-by-default bundles, and treats the whole system as a security product rather than a vendor demo kit.

---

## What makes it notable

- 🧠 **Container-native NPU inference.** On RZ/V2L and the Raspberry Pi 5, the board's neural accelerator runs inside a rootless Podman container under a dedicated system principal — no root, no capability widening, a per-principal subuid namespace. Validated on hardware: RZ/V2L DRP-AI at 27 ms/frame (ResNet18); Raspberry Pi 5 DX-M1 at 271.88 FPS (YOLOv5S 640×640, benchmark mode) through a rootless Quadlet reaching the host's accelerator daemon over a bind-mounted IPC socket. The VENTUNO Q's Hexagon NPU is not integrated (see its board page).

- 🔒 **Signed boot chain.** On RZ/V2L and the Pi, U-Boot verifies an RSA-2048-signed FIT image against a key in its control DTB (on RZ/V2L after TF-A from the Renesas CIP fork and OP-TEE as BL32). A file key covers the dev profile; the signing slot is designed for HSM/YubiKey-ROT in production. Every board mounts its rootfs through dm-verity; the VENTUNO Q has no secure boot, so there verity detects corruption but does not authenticate the image.

- 🔄 **RAUC A/B OTA with automatic rollback.** Signed, encrypted-by-default (RAUC crypt format) bundles, atomic install, boot-count fallback (U-Boot on RZ/V2L and the Pi, systemd-boot on the VENTUNO Q). Kernel/DTB and rootfs update paths both validated on hardware, as is mTLS HTTPS streaming install — a 253 MB bundle streamed from the update server straight into the inactive slot, with no local copy and the transfer running as an unprivileged user.

- 🧱 **Board-agnostic.** A board joins with a kas BSP fragment and a machine fragment, a board-facts include and vendor-gated bbappends under `dynamic-layers/`; distro, image recipes and hardening are shared. The Raspberry Pi 5 is composed this way on a mainline-stable 6.18 kernel. The VENTUNO Q adds a second boot-chain family, `uefi-uki` (ADR-0016), on the vendor's linux-qcom 6.18 kernel.

- 📋 **SBOM + CVE scanning in the default build.** SPDX 3.0.1 generated for every image; NVD and CVE-list scanning wired in. No opt-in; it's part of the baseline, not an afterthought.

---

## Quick start

```bash
# 1. Provide operator credentials (never committed)
cp kas/local.yml.example kas/local.yml
$EDITOR kas/local.yml          # set EDGE_DEFAULT_PASSWORD_HASH (openssl passwd -6)

# 2. Generate the dev RAUC PKI (required: bundle encryption is on by default)
./scripts/rauc-init-certs.sh

# 3. Build
make base                      # edge-image-base for RZ/V2L (~1–3 h cold cache; fast on warm sstate)
make dev                       # edge-image-dev — adds shell tools (and OP-TEE userspace on RZ/V2L)
make base BOARD=raspberrypi5   # same for the Raspberry Pi 5; output under build/raspberrypi5/
make dev BOARD=ventuno-q       # VENTUNO Q (dev tier); output under build/ventuno-q/

# 4. Flash (RZ/V2L and Pi: SD card; VENTUNO Q: eMMC over EDL, see its board page)
sudo bmaptool copy \
  build/rzv2l/tmp/deploy/images/smarc-rzv2l/edge-image-base-smarc-rzv2l.rootfs.wic.zst \
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
- **[docs/dev/emmc/ventuno-q.md](docs/dev/emmc/ventuno-q.md)** — VENTUNO Q install, update, recovery and limitations

---

**Hardware:** Renesas RZ/V2L SMARC EVK (dual Cortex-A55 + DRP-AI accelerator); Raspberry Pi 5 (quad Cortex-A76, PCIe accelerator slot); Arduino VENTUNO Q (Qualcomm QCS8275: 4x Cortex-A78C + 4x Cortex-A55, Hexagon NPU, STM32H5 co-processor).
**License:** MIT (recipes and configuration in this repo). Upstream firmware (TF-A, U-Boot, OP-TEE) carries its respective BSD/GPL license.

*Reference implementation — not certified, not for fleet deployment as-is.*
