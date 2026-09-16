# Board catalogue

Boards this repo can target. Multi-machine layout is in place; only
the wired entry has KAS overlays today.

| Board | Machine | KAS machine overlay | Status | Notes |
|---|---|---|---|---|
| Renesas RZ/V2L SMARC EVK | `smarc-rzv2l` | `kas/machines/rzv2l.yml` | wired (v0) | First board; dev-board for the EDGE AI OS platform. |
| Raspberry Pi 5 | `raspberrypi5` | `kas/machines/raspberrypi5.yml` | wired | Second board. Mainline 6.18 kernel (ADR-0011), U-Boot 2026.01, GPT layout, board facts in `conf/machine/include/edge-board-raspberrypi5.inc`. DEEPX DX-M1 composed via `kas/accel/dxm1.yml`. Boot, RAUC install/slot switch and DX-M1 device identification hardware-validated; rollback matrix and inference not yet run. |
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
