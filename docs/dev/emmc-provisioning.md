# eMMC provisioning (GPT boot target)

How to put an `EDGE_BOOT_TARGET=emmc` image onto the RZ/V2L eMMC and boot it.

This is the one-time provisioning flow for the GPT/eMMC layout. Once the eMMC
holds the bootloader (in its hardware boot partition) and the GPT user-area
image, the board boots from eMMC and `edge-grow-data.service` grows `/data` on
first boot. The SD/eSD path is unchanged and remains the recovery path.

## What goes where

Per the RZ/V2L Linux Start-up Guide ("How to boot from eMMC"):

| Artifact | Destination | Offset |
|----------|-------------|--------|
| BL2 (`bl2_bp_mmc-…`) | `mmcblk0boot0` (hardware boot partition) | sector 1 |
| FIP (`fip-…`)        | `mmcblk0boot0` (hardware boot partition) | sector 256 |
| GPT image (`…-emmc…wic`) | `mmcblk0` user area | — |
| U-Boot env | `mmcblk0` user area, gap below `/boot` | 0x1F0000 |

The mask ROM loads BL2 from `boot0`; BL2 loads FIP from `boot0`. **Neither is
in the user area** — so the user-area image is a clean GPT (no raw bootloader
region), and WIC never touches `boot0`. The same loader binaries serve SD and
eMMC (TF-A reads a boot register to pick the source).

## Prerequisites

1. Build the eMMC image:
   ```
   make dev VIRT=1 EDGE_BOOT_TARGET=emmc
   ```
   Deploy dir then has the GPT `…-emmc` wic plus the loaders:
   `bl2_bp_mmc-smarc-rzv2l_pmic.{bin,srec}`, `fip-smarc-rzv2l_pmic.{bin,srec}`.
2. A serial console to the board, and a host USB cable to the board's
   micro-USB **function** port (for U-Boot `ums` in Step 2, Option A). The
   provisioning-Linux alternative (Option B) instead needs a way to run Linux
   with the eMMC visible on SDHI0 (`SW1-2=eMMC`) — e.g. a carrier-SD or netboot
   rootfs.

## Step 1 — bootloader into boot0 (serial Flash Writer)

For a blank eMMC, `boot0` is programmed with the serial Flash Writer (the eMMC
is not yet visible to Linux). Set SCIF-download boot mode, load Flash Writer to
RAM (Start-up Guide §4.3), then:

```
EM_SECSD                       # enable boot: EXT_CSD 0xB1=0x02, 0xB3=0x08
EM_W  -> Boot Partition 1, start sector 1,   send bl2_bp_mmc-smarc-rzv2l_pmic.srec
EM_W  -> Boot Partition 1, start sector 256, send fip-smarc-rzv2l_pmic.srec
```

(Once `boot0` carries a valid bootloader, later updates can be done from Linux
— `edge-emmc-provision.sh --bl2/--fip` writes the same sectors and sets the
same EXT_CSD bits.)

## Step 2 — GPT image into the user area

Two ways to write the user area. Option A (U-Boot `ums`) is the usual one: it
needs no second OS and touches only the user area, so it also serves as the
day-to-day dev re-flash (`boot0` is left intact).

### Option A — U-Boot `ums` (recommended)

With the board in eMMC boot mode (switches below), interrupt U-Boot and export
the eMMC user area as USB mass storage to the host:

```
=> ums 0 mmc 0
```

`ums 0 mmc 0` maps `mmc 0` — the `mmcblk0` user area only, not `boot0`. The host
enumerates it as a ~59 GB disk. Identify it and **confirm it is the UMS disk,
never a host disk**, then write with the bmap (sparse) and stop `ums`:

```
lsblk -o NAME,SIZE,MODEL          # the new ~59 GB 'MassStorageClass' disk = /dev/sdX
sudo bmaptool copy edge-image-dev-smarc-rzv2l.rootfs.wic.zst /dev/sdX
# Ctrl-C on the U-Boot console to stop ums, then:
=> reset
```

### Option B — provisioning Linux + helper script

When U-Boot/USB-gadget is unavailable, boot a Linux with the eMMC visible on
SDHI0 and write it with the helper. Identify the eMMC (the `mmcblkX` that has
`mmcblkXboot0`, not the running root):

```
ls /sys/block/*/boot0
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

The script verifies GPT, refuses the running-root device, and needs
`zstd`/`bmaptool` for a `.wic.zst` (install them or pre-decompress):

```
sudo ./edge-emmc-provision.sh \
    --wic   edge-image-dev-smarc-rzv2l.rootfs.wic.zst \
    --target /dev/mmcblkX
```

## Boot-mode switches

Two banks select the boot source: **SW1** on the SMARC *module* (media +
debug) and **SW11** on the *carrier* board (boot mode, 4 positions).

| Switch | Where | SD / eSD boot | SCIF download | eMMC boot |
|--------|-------|---------------|---------------|-----------|
| SW1-1 (DEBUGEN) | module  | ON (normal)           | ON (normal)           | ON (normal)             |
| SW1-2 (media)   | module  | ON (microSD)          | OFF (eMMC)            | OFF (eMMC)              |
| SW11 (boot mode)| carrier | ON, ON, OFF, ON       | OFF, ON, OFF, ON      | ON, OFF, OFF, ON        |

The module eMMC and module microSD share SDHI0 and are **mutually exclusive**
via SW1-2 — to touch the eMMC, SW1-2 must be OFF, which disconnects the module
microSD. When eMMC-booted the eMMC enumerates as **mmc 0 / `/dev/mmcblk0`**, so
the U-Boot env (`CONFIG_SYS_MMC_ENV_DEV=0`) and raw `fw_env.config` offsets
apply unchanged — no env relocation. During provisioning the eMMC may be a
different node; pass it via `--target`.

## First boot

The eMMC U-Boot env starts blank: Boot 1 reports an invalid env CRC (expected),
falls back to built-in defaults, and `rauc-uboot-env-init` writes the managed
env; reboot once to settle. `edge-grow-data.service` grows `/data` to fill the
eMMC (seed is 1 GiB): `systemd-repart` resizes the partition and relocates the
backup GPT header to the true end, then `resize2fs` grows the ext4.

## Recovery

A bad eMMC provision does not touch any SD. Reselect SD/eSD boot
(SW1-2=ON, SW11=ON,ON,OFF,ON) and boot the carrier/module SD unchanged.

## Verification (on the eMMC-booted board)

```
sudo sfdisk -l /dev/mmcblk0 | grep -i 'Disklabel type'   # gpt
lsblk -o NAME,PARTLABEL,FSTYPE,SIZE /dev/mmcblk0          # boot/rootfsA/rootfsB/data
ls -l /dev/disk/by-rauc-slot/                            # slot aliases resolve (by PARTLABEL)
findmnt /data ; df -h /data                              # grown past the 1 GiB seed
rauc status                                              # slot A healthy
```
