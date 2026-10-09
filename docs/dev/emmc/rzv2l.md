# eMMC provisioning — RZ/V2L

How to put an [eMMC-target](README.md) image onto the RZ/V2L SMARC EVK eMMC and boot
it. This is the one-time provisioning flow; afterwards the board boots from eMMC.
The SD/eSD path is unchanged and remains the recovery path.

## What goes where

Per the RZ/V2L Linux Start-up Guide ("How to boot from eMMC"):

| Artifact | Destination | Offset |
|----------|-------------|--------|
| BL2 (`bl2_bp_mmc-…`) | `mmcblk0boot0` (hardware boot partition) | sector 1 |
| FIP (`fip-…`)        | `mmcblk0boot0` (hardware boot partition) | sector 256 |
| GPT image (`…-emmc…wic`) | `mmcblk0` user area | — |
| U-Boot env | `mmcblk0` user area, gap below `/boot` | 0x1F0000 |

The mask ROM loads BL2 from `boot0`; BL2 loads the FIP from `boot0`. Neither is in
the user area, so the user-area image is a clean GPT and WIC never touches `boot0`.
The same loader binaries serve SD and eMMC (TF-A reads a boot register to pick the
source). Later bootchain updates use `rzv2l-bootloader-update --mode emmc`
([bootchain](../bootchain/rzv2l.md)).

## Prerequisites

1. `make dev EDGE_BOOT_TARGET=emmc` — the deploy directory then has the GPT `…-emmc`
   wic plus `bl2_bp_mmc-smarc-rzv2l_pmic.{bin,srec}` and
   `fip-smarc-rzv2l_pmic.{bin,srec}`.
2. A serial console, and a host USB cable to the board's micro-USB **function** port
   for U-Boot `ums` (Option A below). Option B instead needs a Linux running with the
   eMMC visible on SDHI0 (`SW1-2` OFF), e.g. a carrier-SD or netboot rootfs.

Switch settings for every boot mode are in the
[bootchain page](../bootchain/rzv2l.md#boot-source-and-switches). SW1-2 connects
SDHI0 to the module microSD or the module eMMC, never both: when eMMC-booted the eMMC
is `mmc 0` / `/dev/mmcblk0`, so the U-Boot env (`CONFIG_SYS_MMC_ENV_DEV=0`) and the
raw `fw_env.config` offsets apply unchanged. During provisioning the eMMC may be a
different node; pass it with `--target`.

## Step 1 — bootloader into boot0 (serial Flash Writer)

A blank eMMC's `boot0` is programmed with the serial Flash Writer (the eMMC is not
yet visible to Linux). Set SCIF-download boot mode, load Flash Writer to RAM
(Start-up Guide §4.3), then:

```
EM_SECSD                       # enable boot: EXT_CSD 0xB1=0x02, 0xB3=0x08
EM_W  -> Boot Partition 1, start sector 1,   send bl2_bp_mmc-smarc-rzv2l_pmic.srec
EM_W  -> Boot Partition 1, start sector 256, send fip-smarc-rzv2l_pmic.srec
```

Once `boot0` carries a valid bootloader, `edge-emmc-provision.sh --bl2/--fip` writes
the same sectors from Linux and sets the same EXT_CSD bits.

## Step 2 — GPT image into the user area

Option A (U-Boot `ums`) needs no second OS and touches only the user area, so it is
also the day-to-day dev re-flash (`boot0` is left intact).

### Option A — U-Boot `ums`

In eMMC boot mode, interrupt U-Boot and export the eMMC user area to the host as USB
mass storage:

```
=> ums 0 mmc 0
```

`ums 0 mmc 0` maps the `mmcblk0` user area only, not `boot0`. The host enumerates a
~59 GB disk. **Confirm it is the UMS disk, never a host disk**, then write with the
bmap and stop `ums`:

```
lsblk -o NAME,SIZE,MODEL          # the new ~59 GB 'MassStorageClass' disk = /dev/sdX
sudo bmaptool copy edge-image-dev-smarc-rzv2l.rootfs.wic.zst /dev/sdX
# Ctrl-C on the U-Boot console to stop ums, then:
=> reset
```

### Option B — provisioning Linux + helper script

Boot a Linux with the eMMC visible on SDHI0 and identify the eMMC (the `mmcblkX` that
has `mmcblkXboot0`, not the running root):

```
ls /sys/block/*/boot0
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

The script verifies GPT, refuses the running-root device, and needs `zstd`/`bmaptool`
for a `.wic.zst`:

```
sudo ./edge-emmc-provision.sh \
    --wic   edge-image-dev-smarc-rzv2l.rootfs.wic.zst \
    --target /dev/mmcblkX
```

## Recovery

A bad eMMC provision does not touch any SD. Select SD/eSD boot (SW1-2 ON, SW11
`ON, ON, OFF, ON`) and boot the SD unchanged.
