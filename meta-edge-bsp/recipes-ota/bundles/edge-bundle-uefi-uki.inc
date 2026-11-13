# uefi-uki bundle content (ADR-0016 §6): both slot UKIs, installed onto the
# ESP by bundle-hooks-uefi-uki.sh through the custom RAUC backend. Required by
# edge-bundle-common.inc.

EDGE_RAUC_UKI_A = "${BUNDLE_IMAGE}${IMAGE_MACHINE_SUFFIX}${IMAGE_NAME_SUFFIX}.uki-A.efi"
EDGE_RAUC_UKI_B = "${BUNDLE_IMAGE}${IMAGE_MACHINE_SUFFIX}${IMAGE_NAME_SUFFIX}.uki-B.efi"

# The root hash and dm table live in the slot UKI. A rootfs-only bundle
# would install a slot that cannot mount its root.
RAUC_BUNDLE_EXTRA_FILES += "${EDGE_RAUC_UKI_A} ${EDGE_RAUC_UKI_B}"
RAUC_BUNDLE_HOOKS[file] = "bundle-hooks-uefi-uki.sh"

# The UKIs are read from the deploy dir by name; their content is in the task
# hash so a rebuilt UKI is not bundled from a stale sstate object.
python __anonymous() {
    deploy_dir = d.getVar("DEPLOY_DIR_IMAGE")
    files = (d.getVar("EDGE_RAUC_UKI_A"), d.getVar("EDGE_RAUC_UKI_B"))
    checksums = d.getVarFlag("do_configure", "file-checksums") or ""
    entries = ["%s/%s:True" % (deploy_dir, name) for name in files]
    d.setVarFlag("do_configure", "file-checksums", (checksums + " " + " ".join(entries)).strip())
}

FILESEXTRAPATHS:prepend := "${THISDIR}/../rauc/files:"
SRC_URI:append = " file://bundle-hooks-uefi-uki.sh;mode=0755"

do_unpack[postfuncs] += "edge_bundle_substitute_uki_names"
edge_bundle_substitute_uki_names() {
    sed -i \
        -e "s|@UKI_IMAGE_A@|${EDGE_RAUC_UKI_A}|g" \
        -e "s|@UKI_IMAGE_B@|${EDGE_RAUC_UKI_B}|g" \
        -e "s|@SDBOOT_BACKEND@|${libexecdir}/edge-sdboot-backend|g" \
        "${UNPACKDIR}/bundle-hooks-uefi-uki.sh"
    if grep -q '@[A-Z_]*@' "${UNPACKDIR}/bundle-hooks-uefi-uki.sh"; then
        bbfatal "Unexpanded @TOKEN@ left in bundle-hooks-uefi-uki.sh"
    fi
}
