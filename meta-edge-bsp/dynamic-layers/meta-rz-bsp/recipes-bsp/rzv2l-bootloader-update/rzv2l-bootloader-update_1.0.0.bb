SUMMARY     = "Guarded on-target BL2/FIP bootchain updater for RZ/V2L"
DESCRIPTION = "Installs a hash-verified updater plus the BL2/FIP artifacts and a \
manifest, so a running board can rewrite its QSPI/eSD/eMMC bootchain (TF-A, \
OP-TEE, U-Boot) outside the RAUC rootfs flow."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "bootloaders"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "smarc-rzv2l"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit deploy

SRC_URI = "file://rzv2l-bootloader-update.sh"
S = "${UNPACKDIR}"

RDEPENDS:${PN} = "bash coreutils util-linux mtd-utils"

# BL2/FIP (bl2_bp_{spi,esd,mmc}-${MACHINE}[_pmic].bin, fip-${MACHINE}[_pmic].bin)
# are produced by firmware-pack's do_deploy into DEPLOY_DIR_IMAGE.
do_install[depends] += "firmware-pack:do_deploy"
do_deploy[depends]  += "firmware-pack:do_deploy"

# Per-mode FIP location, as TF-A reads it: QSPI absolute 0x20000 (the "fip"
# partition starts at 0x1d000, so mtd1 + 0x3000), eSD byte 0x20000, eMMC boot0
# sector 256 (BL2 at boot0 sector 1). The tool derives the QSPI offset from
# sysfs; target/offset here document it. Columns: filename sha256 size mode
# target offset variant.
rzv2l_bl_collect() {
    local dest="$1"
    install -d "$dest"
    for f in \
        ${DEPLOY_DIR_IMAGE}/bl2_bp_spi-${MACHINE}.bin \
        ${DEPLOY_DIR_IMAGE}/bl2_bp_spi-${MACHINE}_pmic.bin \
        ${DEPLOY_DIR_IMAGE}/bl2_bp_esd-${MACHINE}.bin \
        ${DEPLOY_DIR_IMAGE}/bl2_bp_esd-${MACHINE}_pmic.bin \
        ${DEPLOY_DIR_IMAGE}/bl2_bp_mmc-${MACHINE}.bin \
        ${DEPLOY_DIR_IMAGE}/bl2_bp_mmc-${MACHINE}_pmic.bin \
        ${DEPLOY_DIR_IMAGE}/fip-${MACHINE}.bin \
        ${DEPLOY_DIR_IMAGE}/fip-${MACHINE}_pmic.bin; do
        [ -f "$f" ] || bbfatal "bootchain artifact missing: $f"
        install -m 0644 "$f" "$dest"/
    done
}

rzv2l_bl_manifest() {
    local dir="$1" manifest="$2" f base sha size variant mode target offset
    printf "filename\tsha256\tsize\tmode\ttarget\toffset\tvariant\n" > "$manifest"
    for f in "$dir"/*.bin; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        sha="$(sha256sum "$f" | awk '{print $1}')"
        size="$(stat -c%s "$f")"
        variant="non-pmic"; case "$base" in *_pmic.bin) variant="pmic" ;; esac
        case "$base" in
            bl2_bp_spi-*) mode="qspi"; target="/dev/mtd0";        offset="0x0" ;;
            # bl2_bp_esd is written at sector 1 (0x200); the MBR at sector 0 is
            # left intact, so BL2 code lands at 0x1000 as the ROM expects.
            bl2_bp_esd-*) mode="esd";  target="/dev/mmcblk0";     offset="0x200" ;;
            bl2_bp_mmc-*) mode="emmc"; target="/dev/mmcblk0boot0"; offset="0x200" ;;
            fip-*)
                printf "%s\t%s\t%s\tqspi\t/dev/mtd1\t0x3000\t%s\n"   "$base" "$sha" "$size" "$variant" >> "$manifest"
                printf "%s\t%s\t%s\tesd\t/dev/mmcblk0\t0x20000\t%s\n" "$base" "$sha" "$size" "$variant" >> "$manifest"
                printf "%s\t%s\t%s\temmc\t/dev/mmcblk0boot0\t0x20000\t%s\n" "$base" "$sha" "$size" "$variant" >> "$manifest"
                continue ;;
            *) continue ;;
        esac
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$base" "$sha" "$size" "$mode" "$target" "$offset" "$variant" >> "$manifest"
    done
}

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${S}/rzv2l-bootloader-update.sh ${D}${sbindir}/rzv2l-bootloader-update
    install -d ${D}${datadir}/rzv2l-boot
    rzv2l_bl_collect ${D}${datadir}/rzv2l-boot
    rzv2l_bl_manifest ${D}${datadir}/rzv2l-boot ${D}${datadir}/rzv2l-boot/manifest.tsv
}

# Host-side package (`make bootloader-package`) for out-of-band provisioning.
do_deploy() {
    install -d ${DEPLOYDIR}/rzv2l-bootloader
    rzv2l_bl_collect ${DEPLOYDIR}/rzv2l-bootloader
    rzv2l_bl_manifest ${DEPLOYDIR}/rzv2l-bootloader ${DEPLOYDIR}/rzv2l-bootloader/manifest.tsv
    install -m 0755 ${S}/rzv2l-bootloader-update.sh ${DEPLOYDIR}/rzv2l-bootloader/
    tar -C ${DEPLOYDIR}/rzv2l-bootloader -czf ${DEPLOYDIR}/rzv2l-bootloader-${MACHINE}.tar.gz .
}
addtask deploy after do_install

FILES:${PN} = "${sbindir}/rzv2l-bootloader-update ${datadir}/rzv2l-boot"
