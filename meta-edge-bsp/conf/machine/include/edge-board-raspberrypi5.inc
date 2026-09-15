# Board facts for the Raspberry Pi 5, consumed by the distro's board
# contracts. One file per board; this is the second.
#
# Pulled in by MACHINE name from edge-ai.conf, after conf/machine/
# raspberrypi5.conf and its rpi-base.inc. EDGE_BOARD_INC is the sentinel that
# turns a missing board file into a readable parse failure.
#
# Same assignment rule as the RZ/V2L file: `?=` for values only this file
# declares (an operator override in kas/local.yml still wins), plain `=` for
# values the distro pre-declares with ??= or the vendor machine conf sets.

EDGE_BOARD_INC = "1"

# --- Accelerator ---------------------------------------------------------
# DEEPX DX-M1 on the PCIe M.2 slot. Allowlist only; the selection is
# EDGE_ACCEL from kas/accel/dxm1.yml once that fragment exists. Until then the
# machine fragment sets EDGE_ALLOW_NO_ACCEL for bring-up.
EDGE_ACCEL_SUPPORTED = "dxm1"

# --- Network interface roles --------------------------------------------
# One wired interface (RP1 ethernet) and it is the uplink; nothing is
# reserved for a kernel netboot path.
EDGE_UNMANAGED_IFACES = ""
EDGE_UPLINK_IFACE     = "eth0"

# --- Boot chain ---------------------------------------------------------
# EEPROM boot ROM -> U-Boot (loaded as kernel_2712.img from the FAT
# partition) -> signed FIT verified against the key in the board DTB ->
# raw U-Boot env for RAUC boot-count.
EDGE_BOOT_CHAIN = "uboot-fit"

# --- Kernel provider ----------------------------------------------------
# Mainline stable 6.18 (ADR-0011); the vendor recipes are masked in
# kas/bsp/raspberrypi-kernel.yml. sbom-cve-check sets the SPDX
# compiled-sources flag for linux-yocto only.
SPDX_INCLUDE_COMPILED_SOURCES:pn-linux-edge-mainline = "1"

# Mainline 6.18 builds one DTB for this board. rpi-base.inc lists the CM5
# variants and ~70 vendor overlays, none of which the mainline tree has;
# plain `=` beats its ??=.
KERNEL_DEVICETREE = "broadcom/bcm2712-rpi-5-b.dtb"

# --- Partition layout ---------------------------------------------------
# GPT (files/wic/edge-rpi5.wks.in): boot p1, rootfs A p2, rootfs B p3,
# data p4. Slot identity for udev comes from the GPT partition names; the
# device paths below are written into the signed dm-verity table and the
# U-Boot env defaults, where a wrong value is a correctly-signed image that
# cannot mount its own root. mmcblk0 is the SD card, the only MMC host.
EDGE_PTABLE = "gpt"
EDGE_BOOT_DEVICE   ?= "/dev/mmcblk0p1"
EDGE_SLOT_A_DEVICE ?= "/dev/mmcblk0p2"
EDGE_SLOT_B_DEVICE ?= "/dev/mmcblk0p3"
EDGE_DATA_DEVICE   ?= "/dev/mmcblk0p4"

# --- Raw U-Boot environment area ----------------------------------------
# Redundant raw-MMC environment in the gap between the GPT tables and p1
# (4 MiB aligned), not a FAT file: fw_setenv then needs no mounted
# filesystem and the redundant copy makes RAUC's boot-count update atomic.
# Must match CONFIG_ENV_OFFSET / CONFIG_ENV_OFFSET_REDUND / CONFIG_ENV_SIZE
# in the U-Boot fragment (edge-rpi5-boot.cfg); the bbappend asserts the
# resolved .config carries these values.
EDGE_UBOOT_ENV_DEVICE        ?= "/dev/mmcblk0"
EDGE_UBOOT_ENV_OFFSET        ?= "0x1F0000"
EDGE_UBOOT_ENV_OFFSET_REDUND ?= "0x210000"
EDGE_UBOOT_ENV_SIZE          ?= "0x20000"

# --- FIT trust anchor ---------------------------------------------------
# U-Boot on this board runs with the firmware-passed DTB as its control FDT
# (CONFIG_OF_BOARD), and the firmware loads that DTB from the FAT partition.
# It is the kernel-built board DTB; the kernel recipe injects the FIT public
# key into it at deploy, so the same file is both the runtime control FDT
# and the fdt image inside the signed slot FITs.
EDGE_FIT_PUBKEY_DTB ?= "bcm2712-rpi-5-b.dtb"

# --- Machine-specific image content -------------------------------------
# No SPI flash tooling and no OP-TEE: the board has neither. On-board
# CYW43455 radio: the WiFi firmware, the regulatory database cfg80211
# requests at init, and the Bluetooth patch firmware hci_uart_bcm requests
# for hci0 (no Bluetooth userspace is installed; the controller initialises
# and stays idle). The vendor machine conf recommends the firmware for both
# radio variants through packagegroup-machine-base; kas/machines/
# raspberrypi5.yml removes those recommends and the fitted variant is named
# here. edge-io-udev: gpio group + gpiochip rule, in place of the vendor
# udev-rules-rpi (removed there too; its rules target the vendor kernel and
# name groups this distro does not create, which stalls udevd at start).
EDGE_MACHINE_EXTRA_INSTALL ?= "linux-firmware-rpidistro-bcm43455 bluez-firmware-rpidistro-bcm4345c0-hcd wireless-regdb-static edge-io-udev"

# devel joins the I/O groups the board's recipes create. i2c and spi are not
# offered: mainline 6.18 exposes no RP1 header I2C/SPI controller for this
# board, only two SoC-internal I2C buses, and no spidev node.
EDGE_BOARD_DEVEL_GROUPS = "gpio"

# --- Boot artifacts (contract in edge-ab-image.bbclass) ------------------
# The FAT partition carries what the EEPROM boot ROM reads: config.txt
# (rpi-config), U-Boot under the firmware's default 64-bit kernel filename,
# and the board DTB. No cmdline.txt: the kernel command line comes from the
# signed slot DTB, and no overlays: mainline ships none.
EDGE_BOOT_DTB         ?= "bcm2712-rpi-5-b.dtb"
EDGE_BOOT_EXTRA       ?= "bootfiles/config.txt;config.txt bcm2712-rpi-5-b.dtb u-boot.bin;kernel_2712.img"
EDGE_BOOT_DEPLOY_DEPS ?= "rpi-bootfiles:do_deploy u-boot:do_deploy virtual/kernel:do_deploy"

# --- FIT runtime addresses ----------------------------------------------
# 0x80000 is text_offset into the first 2 MiB boundary, the address the
# arm64 Image header asks for on this SoC. U-Boot stages the FIT itself at
# loadaddr (0x08000000, edge-rpi5-boot.cfg) well above the decompressed
# kernel, so bootm never overwrites the image it is decompressing.
EDGE_FIT_LOADADDRESS ?= "0x00080000"
EDGE_FIT_ENTRYPOINT  ?= "0x00080000"

# --- Signed kernel command line -----------------------------------------
# PCIe ASPM off. With ASPM active the BCM2712 root port lets the DX-M1
# endpoint enter a low-power link state from which its config space reads
# back as reset; the driver's link-health worker then takes a config-space
# read that BCM2712 escalates to a fatal SError (a panic from a workqueue,
# on a ~10 s cadence). Global, so it also covers the RP1 link. The
# accelerator is always fitted on this board, so this is a board fact in the
# signed command line, not an accelerator-conditional append.
EDGE_VERITY_KERNEL_ARGS:append = " pcie_aspm=off"

# --- WIC layout ----------------------------------------------------------
# Plain `=`: rpi-base.inc declares WKS_FILE ?= and this file parses after it.
WKS_FILE = "edge-rpi5.wks.in"
