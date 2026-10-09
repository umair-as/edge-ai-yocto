# eMMC boot target

`EDGE_BOOT_TARGET=emmc` builds the image for a board that boots from its eMMC: a GPT
user-area image with the same A/B layout as the SD image, grown to the device on
first boot ([ADR-0006](../../adr/0006-emmc-gpt-boot-target.md)). Each board's
`conf/machine/include/edge-board-<machine>.inc` maps the target to its WKS layout;
the default, `esd`, builds the SD image.

## Boards

| Board (`BOARD=`) | eMMC target | Page |
|---|---|---|
| `rzv2l` | supported: bootloader in `mmcblk0boot0`, GPT user area | [rzv2l.md](rzv2l.md) |
| `raspberrypi5` | not applicable: the Pi 5 has no eMMC; its SD image is already GPT | — |

## Build

```bash
make dev EDGE_BOOT_TARGET=emmc BOARD=<board>
make bundle EDGE_BOOT_TARGET=emmc BOARD=<board>   # bundles for an eMMC-booted board
```

A bundle must be built for the target the board boots: an SD-target bundle carries
the SD grow path, which fails on the GPT layout.

## Layout

The user area holds a clean GPT: `boot`, `rootfsA`, `rootfsB` and `data`, with the
U-Boot environment in the raw gap below `/boot` at `EDGE_UBOOT_ENV_OFFSET`. Where
the bootloader lives — a hardware boot partition or the user area — is the board's
choice, on its page.

## First boot

The eMMC U-Boot env starts blank: the first boot reports an invalid env CRC
(expected), falls back to the built-in defaults, and `rauc-uboot-env-init` writes the
managed env; one reboot settles it. `edge-grow-data.service` grows `/data` to fill
the eMMC from its 1 GiB seed: `systemd-repart` resizes the partition and moves the
backup GPT header to the true end of the device, then `resize2fs` grows the ext4.

## Verification (on the eMMC-booted board)

```
sudo sfdisk -l /dev/mmcblk0 | grep -i 'Disklabel type'   # gpt
lsblk -o NAME,PARTLABEL,FSTYPE,SIZE /dev/mmcblk0          # boot/rootfsA/rootfsB/data
ls -l /dev/disk/by-rauc-slot/                            # slot aliases resolve (by PARTLABEL)
findmnt /data ; df -h /data                              # grown past the 1 GiB seed
rauc status                                              # slot A healthy
```
