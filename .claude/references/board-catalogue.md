# Board catalogue

Boards this repo can target. Multi-machine layout is in place; only
the wired entry has KAS overlays today.

| Board | Machine | KAS machine overlay | Status | Notes |
|---|---|---|---|---|
| Renesas RZ/V2L SMARC EVK | `smarc-rzv2l` | `kas/machines/rzv2l.yml` | wired (v0) | First board; dev-board for the EDGE AI OS platform. |
| Raspberry Pi 5 | `raspberrypi5` | `kas/machines/raspberrypi5.yml` | wired | Second board. Mainline 6.18 kernel (ADR-0011), U-Boot 2026.01, GPT layout, board facts in `conf/machine/include/edge-board-raspberrypi5.inc`. DEEPX DX-M1 composed via `kas/accel/dxm1.yml`. Boot, RAUC install/slot switch, DX-M1 device identification and rootless inference through the shipped Quadlet all hardware-validated; the rollback matrix has been run on RZ/V2L only. |
| Arduino VENTUNO Q (ABX00181) | `ventuno-q` | `kas/machines/ventuno-q.yml` | booted, OTA validated (dev) | Third board, Qualcomm QCS8275. `uefi-uki` boot chain (ADR-0016): Qualcomm firmware and UEFI untouched, systemd-boot on the ESP, one UKI per A/B slot on the ESP, RAUC `custom` backend (`edge-sdboot-backend`, boot counting in UKI file names, no EFI variable written), trust anchor `none`. Kernel `linux-qcom` 6.18 (ADR-0011 decision 6). No accelerator stack composed. Prod images fail at the trust-anchor gate by design; no KSPP baseline. Installed and recovered through EDL with `scripts/dev/ventunoq-flash.py` (`docs/dev/emmc/ventuno-q.md`). Ethernet does not carry traffic on this image. |
| _slot_ | _tbd_ | `kas/machines/<board>.yml` | not wired | Add new machine overlays here as siblings are added. |

## Adding a new board

1. Verify a maintained BSP layer (e.g. `meta-renesas` for RZ family,
   or the equivalent vendor / community layer for the SoC) provides a
   machine conf for the target. If not, the board is out of scope
   until one exists.
2. Add `kas/machines/<board>.yml` mirroring the rzv2l overlay — short
   include of the upstream machine yml.
3. Add a row above with status `not wired` until the first build
   succeeds.
4. Once base boot passes on the new board, flip status to `wired`
   and add any board-specific overlays (DTS patches, U-Boot defconfig
   deltas) under `meta-edge-bsp/recipes-{kernel,bsp}/`.

## Why a catalogue file at all

The repo name (`edge-ai-yocto`) is deliberately board-agnostic. This
file is the legible record of what boards the layout supports today
versus tomorrow, so a contributor can see at a glance whether their
target is already wired.
