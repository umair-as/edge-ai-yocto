# uboot-fit bundle content: the signed slot FITs and the U-Boot env defaults,
# installed by bundle-hooks.sh. Required by edge-bundle-common.inc.

EDGE_RAUC_FIT_A = "${BUNDLE_IMAGE}${IMAGE_MACHINE_SUFFIX}${IMAGE_NAME_SUFFIX}.fitImage-A"
EDGE_RAUC_FIT_B = "${BUNDLE_IMAGE}${IMAGE_MACHINE_SUFFIX}${IMAGE_NAME_SUFFIX}.fitImage-B"
EDGE_RAUC_TRACK_DEPLOY_FILES ?= ""

# The root hash and dm table live in the signed slot FIT. A rootfs-only
# bundle would install an unbootable or unauthenticated slot.
RAUC_BUNDLE_EXTRA_FILES += "${EDGE_RAUC_FIT_A} ${EDGE_RAUC_FIT_B}"
RAUC_BUNDLE_HOOKS[file]    = "bundle-hooks.sh"

# Track selected deploy artifacts in the task hash so sstate invalidates
# on content changes.
python __anonymous() {
    deploy_dir = d.getVar("DEPLOY_DIR_IMAGE")
    files = []

    extra = (d.getVar("EDGE_RAUC_TRACK_DEPLOY_FILES") or "").split()
    files.extend(extra)

    files.extend((d.getVar("EDGE_RAUC_FIT_A"), d.getVar("EDGE_RAUC_FIT_B")))

    if not files:
        return

    files = list(dict.fromkeys(files))
    checksums = d.getVarFlag("do_configure", "file-checksums") or ""
    entries = [f"{deploy_dir}/{name}:True" for name in files]
    d.setVarFlag("do_configure", "file-checksums", (checksums + " " + " ".join(entries)).strip())
}

# Pick up bundle-hooks.sh from the sibling rauc/files directory.
FILESEXTRAPATHS:prepend := "${THISDIR}/../rauc/files:${THISDIR}/../../recipes-bsp/u-boot/files:"
SRC_URI:append = " file://bundle-hooks.sh;mode=0755 file://rauc-uboot-env.defaults.in "
RAUC_BUNDLE_EXTRA_FILES += "rauc-uboot-env.defaults"

# Substitute image-specific bundle filenames before bundle.bbclass copies the
# hook. Slot selection remains a runtime RAUC decision.
do_unpack[postfuncs] += "edge_bundle_substitute_fit_names"
edge_bundle_substitute_fit_names() {
    sed -i \
        -e "s|@FIT_IMAGE_A@|${EDGE_RAUC_FIT_A}|g" \
        -e "s|@FIT_IMAGE_B@|${EDGE_RAUC_FIT_B}|g" \
        "${UNPACKDIR}/bundle-hooks.sh"

    # The bundle ships the U-Boot env defaults so the update hook can seed a
    # slot's env. Same template and same board facts as rauc-uboot-env's
    # do_install -- the file is shared through FILESEXTRAPATHS above, so the
    # two expansions cannot drift in content, only in whether they happen.
    [ -n "${EDGE_SLOT_A_DEVICE}" ] || bbfatal "EDGE_SLOT_A_DEVICE is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
    [ -n "${EDGE_SLOT_B_DEVICE}" ] || bbfatal "EDGE_SLOT_B_DEVICE is empty; set it in conf/machine/include/edge-board-${MACHINE}.inc"
    sed -e "s|@EDGE_SLOT_A_DEVICE@|${EDGE_SLOT_A_DEVICE}|g" \
        -e "s|@EDGE_SLOT_B_DEVICE@|${EDGE_SLOT_B_DEVICE}|g" \
        "${UNPACKDIR}/rauc-uboot-env.defaults.in" \
        > "${UNPACKDIR}/rauc-uboot-env.defaults"
    if grep -q '@[A-Z_]*@' "${UNPACKDIR}/rauc-uboot-env.defaults"; then
        bbfatal "Unexpanded @TOKEN@ left in the bundle's rauc-uboot-env.defaults"
    fi
}
do_unpack[vardeps] += "EDGE_SLOT_A_DEVICE EDGE_SLOT_B_DEVICE"
