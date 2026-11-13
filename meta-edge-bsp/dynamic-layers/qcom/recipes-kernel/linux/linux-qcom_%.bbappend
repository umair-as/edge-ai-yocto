FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

require ${EDGE_BSP_LAYERDIR}/recipes-kernel/linux/edge-kernel-policy.inc

# kernel.bbclass defaults CVE_PRODUCT to "linux_kernel linux:linux"; the
# second token over-matches unrelated NVD products. PV is already the clean
# stable version.
CVE_PRODUCT = "linux_kernel"

# ventuno-q-mcu.cfg: the STM32H5 co-processor enumerates over USB, CDC-ACM
# for the Bridge RPC and gs_usb for its CAN interfaces.
SRC_URI:append:ventuno-q = " \
    file://0001-arm64-dts-qcom-monaco-monza-som-add-the-SerDes-0.9-V-supply.patch \
    file://cfg/ventuno-q-mcu.cfg \
    file://cfg/ventuno-q-qrtr.cfg \
    file://cfg/wireless-ventuno-q.cfg \
"

# Asserted with the platform symbols. QRTR carries the remoteproc QMI
# services and the pd-mapper; ventuno-q-qrtr.cfg requests it, and the
# assertion catches a later fragment that drops it. The rest is the DSP,
# MCU, radio and boot-path support the board does not work without. EFI
# variables and VFAT carry the boot path: systemd-boot's loader variables and
# ESP, and for RAUC's efi backend the boot entries and efiA/efiB file systems.
EDGE_KERNEL_POLICY_EXTRA_CONFIG:ventuno-q = " \
    CONFIG_QRTR=m \
    CONFIG_QRTR_SMD=m \
    CONFIG_QRTR_MHI=m \
    CONFIG_QCOM_PD_MAPPER=m \
    CONFIG_QCOM_Q6V5_PAS=m \
    CONFIG_QCOM_FASTRPC=m \
    CONFIG_ATH11K_PCI=m \
    CONFIG_POWER_SEQUENCING_PCIE_M2=m \
    CONFIG_USB_ACM=m \
    CONFIG_CAN_GS_USB=m \
    CONFIG_MMC_SDHCI_MSM=y \
    CONFIG_PCIE_QCOM=y \
    CONFIG_SERIAL_QCOM_GENI_CONSOLE=y \
    CONFIG_EFIVAR_FS=y \
    CONFIG_VFAT_FS=y \
    CONFIG_NLS_CODEPAGE_437=y \
    CONFIG_NLS_ISO8859_1=y \
"

# meta-qcom keeps S in UNPACKDIR. oe.spdx_common.get_patched_src() treats
# such an S as private and re-runs do_unpack for SPDX, whose cleandirs
# empty STAGING_KERNEL_DIR and STAGING_KERNEL_BUILDDIR under work-shared.
# S in work-shared takes the copy path instead, as kernel-yocto does.
S = "${STAGING_KERNEL_DIR}"

python edge_move_kernsrc() {
    import shutil
    src = os.path.join(d.getVar("UNPACKDIR"), d.getVar("BP"))
    dst = d.getVar("STAGING_KERNEL_DIR")
    bb.utils.remove(dst, recurse=True)
    shutil.move(src, dst)
    os.symlink(dst, src)
}
# Before create_source_date_epoch_stamp, which reads S.
do_unpack[postfuncs] =+ "edge_move_kernsrc"
