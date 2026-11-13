# Board facts for the Arduino VENTUNO Q, consumed by the distro's board
# contracts. One file per board.
#
# Pulled in by MACHINE name from edge-ai.conf, after meta-qcom-arduino's
# conf/machine/ventuno-q.conf. Same assignment rule as the other board
# files: `?=` for values only this file declares, plain `=` for values the
# distro pre-declares with ??= or the vendor machine conf sets.

EDGE_BOARD_INC = "1"

# --- Identity -----------------------------------------------------------
EDGE_HOSTNAME ?= "edge-ventunoq"
EDGE_KHC_BOARD ?= "ventuno-q"

# --- Accelerator ---------------------------------------------------------
# Hexagon NPU through FastRPC. No accelerator stack for it in this layer;
# the allowlist is empty.
EDGE_ACCEL_SUPPORTED = ""

# --- Network interface roles --------------------------------------------
# One wired interface (stmmac / dwmac-qcom-ethqos) and it is the uplink.
EDGE_UNMANAGED_IFACES = ""
EDGE_UPLINK_IFACE     = "eth0"

# --- Boot chain ---------------------------------------------------------
# Qualcomm XBL -> Qualcomm UEFI -> one UKI per A/B slot (ADR-0016).
EDGE_BOOT_CHAIN = "uefi-uki"

# --- Kernel provider ----------------------------------------------------
# linux-qcom from meta-qcom. sbom-cve-check sets the SPDX compiled-sources
# flag for linux-yocto only.
SPDX_INCLUDE_COMPILED_SOURCES:pn-linux-qcom = "1"

# --- Partition layout ---------------------------------------------------
# Factory GPT p1-p70 kept; slots carved from the factory system region
# (ADR-0016 §4): p69 ESP, p71/p72 efiA/efiB, p73/p74 rootfs A/B, p75 data.
# mmcblk0 is the eMMC, the only MMC host.
EDGE_PTABLE = "gpt"
EDGE_BOOT_DEVICE   ?= "/dev/mmcblk0p69"
EDGE_SLOT_A_DEVICE ?= "/dev/mmcblk0p73"
EDGE_SLOT_B_DEVICE ?= "/dev/mmcblk0p74"
EDGE_DATA_DEVICE   ?= "/dev/mmcblk0p75"

# Install payload (edge-ab-uefi-uki.bbclass): partitions numbered from the
# factory system partition, in the order efiA, efiB, rootfsA, rootfsB, data.
# The slot and data devices above follow that numbering, checked at parse.
EDGE_INSTALL_FIRST_PARTITION = "71"
EDGE_UKI_SLOT_SIZE_MB = "128"
EDGE_DATA_IMAGE_SIZE_MB = "256"

# --- Trust anchor -------------------------------------------------------
# UEFI Secure Boot is off and RPMB is unprovisioned, so no stage verifies
# the UKI that carries the dm-verity root hash (ADR-0016 §2).
EDGE_BOOT_ANCHOR = "none"

# --- Accelerator selection ----------------------------------------------
# No accelerator stack is composed for this board.
EDGE_ALLOW_NO_ACCEL = "1"

# --- Slot payload -------------------------------------------------------
# One UKI per slot embeds this DTB; the dm-verity slot holds the Qualcomm
# DSP/NPU userspace, hence 8 GiB.
EDGE_UKI_DTB = "monaco-arduino-monza.dtb"
EDGE_SLOT_SIZE_MB = "8192"

# --- Kernel command line (UKI .cmdline) ---------------------------------
# GENI UART console on the JCTL header; PCIe PME without MSI, as the
# vendor image boots. ASPM on the PCIe switch port to the M.2 Wi-Fi/BT card
# raises RxErr AER that escalates to an unrecoverable UnsupReq for ath11k
# and xhci, so the policy is performance.
EDGE_VERITY_KERNEL_ARGS:append = " console=ttyMSM0,115200n8 pcie_pme=nomsi pcie_aspm.policy=performance"

# --- OTA userspace ------------------------------------------------------
# No U-Boot environment on this board. The RAUC backend writes no EFI
# variable; a libefivar write would truncate the firmware's variable store
# (ADR-0016).
IMAGE_INSTALL:remove = "virtual-ota-uboot-env u-boot-fw-utils"

# --- Machine-specific image content -------------------------------------
# Remoteproc and GPU firmware come from the vendor machine conf's
# MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS. Its QCA2066 Wi-Fi/BT firmware is
# gated on the wifi and bluetooth DISTRO_FEATURES, which the distro does not
# set, so it is listed here.
EDGE_MACHINE_EXTRA_INSTALL ?= "linux-firmware-ath11k-qca2066 linux-firmware-qca-qca2066 wireless-regdb-static"
# Dev tier: Wi-Fi userspace.
EDGE_MACHINE_DEV_INSTALL = "iw wpa-supplicant"

# --- Static IDs ---------------------------------------------------------
# meta-qcom adds system groups the shared table does not list; a board
# table keeps them out of the other boards' useradd signatures.
USERADD_GID_TABLES:append = " files/group-ventuno-q"
