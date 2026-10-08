SUMMARY     = "Operator-driven Raspberry Pi 5 FAT boot-file updater"
DESCRIPTION = "Guarded wrapper that rewrites U-Boot (kernel_2712.img), the board \
DTB and config.txt on the shared FAT /boot partition, with manifest verification \
and backup/restore. The FAT-file counterpart of rzv2l-bootloader-update; \
operator-run, never wired into RAUC."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "bootloaders"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "raspberrypi5"
PACKAGE_ARCH = "${MACHINE_ARCH}"

SRC_URI = "file://edge-rpi-bootfiles-update.sh"
S = "${UNPACKDIR}"

# Artifacts are collected from DEPLOY_DIR_IMAGE, so run after they are deployed.
# The board DTB must be the FIT-pubkey-injected one virtual/kernel deploys, and
# config.txt/u-boot are the same artifacts the wic places on /boot.
do_install[depends] += "virtual/kernel:do_deploy u-boot:do_deploy rpi-bootfiles:do_deploy"
do_install[vardeps] += "BOOTFILES_DIR_NAME"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/edge-rpi-bootfiles-update.sh ${D}${sbindir}/edge-rpi-bootfiles-update

    install -d ${D}${datadir}/rpi-boot
    manifest=${D}${datadir}/rpi-boot/manifest.tsv
    printf 'artifact\tsha256\tsize\tboot_target\n' > ${manifest}

    # $1 source in DEPLOY_DIR_IMAGE (follows symlinks), $2 on-disk /boot name.
    collect() {
        src="$1"; dst="$2"
        [ -f "$src" ] || bbfatal "edge-rpi-bootfiles-update: deploy artifact not found: $src"
        install -m 0644 "$src" ${D}${datadir}/rpi-boot/"$dst"
        sha=$(sha256sum ${D}${datadir}/rpi-boot/"$dst" | awk '{print $1}')
        sz=$(stat -c%s ${D}${datadir}/rpi-boot/"$dst")
        printf '%s\t%s\t%s\t%s\n' "$dst" "$sha" "$sz" "$dst" >> ${manifest}
    }

    # Names are the literals edge-rpi-bootfiles-update.sh expects on /boot
    # (bcm2712-rpi-5-b.dtb is the FIT-pubkey-injected EDGE_FIT_PUBKEY_DTB;
    # u-boot.bin is deployed as the firmware's kernel_2712.img).
    cfg=${DEPLOY_DIR_IMAGE}/${BOOTFILES_DIR_NAME}/config.txt
    [ -f "$cfg" ] || cfg=${DEPLOY_DIR_IMAGE}/bootfiles/config.txt
    collect "$cfg"                                config.txt
    collect ${DEPLOY_DIR_IMAGE}/bcm2712-rpi-5-b.dtb  bcm2712-rpi-5-b.dtb
    collect ${DEPLOY_DIR_IMAGE}/u-boot.bin           kernel_2712.img
}

FILES:${PN} = "${sbindir}/edge-rpi-bootfiles-update ${datadir}/rpi-boot"
RDEPENDS:${PN} = "bash coreutils util-linux"
