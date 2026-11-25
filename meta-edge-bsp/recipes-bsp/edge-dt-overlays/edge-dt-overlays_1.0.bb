SUMMARY     = "Board device tree overlays for the UKI DTB"
DESCRIPTION = "Compiles the board's device tree overlay sources (.dtso) with symbols and deploys \
the .dtbo files. The uefi-uki image class merges those named in EDGE_UKI_DTB_OVERLAYS into the \
DTB embedded in each slot UKI."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "kernel"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Board bbappends add their .dtso files with a machine override.
SRC_URI = ""

DEPENDS = "dtc-native"

inherit deploy nopackages

PACKAGE_ARCH = "${MACHINE_ARCH}"
S = "${UNPACKDIR}"
B = "${WORKDIR}/build"

do_compile[cleandirs] = "${B}"
do_compile() {
    for src in ${S}/*.dtso; do
        [ -e "$src" ] || continue
        dtc -@ -I dts -O dtb -o "${B}/$(basename "$src" .dtso).dtbo" "$src"
    done
}

do_deploy() {
    for dtbo in ${B}/*.dtbo; do
        [ -e "$dtbo" ] || continue
        install -m 0644 "$dtbo" ${DEPLOYDIR}/
    done
}
addtask deploy after do_compile before do_build
