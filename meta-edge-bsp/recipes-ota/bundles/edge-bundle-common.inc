LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit bundle edge-wic-label-check

# Single source of truth: must match rauc-conf-edge byte-for-byte.
RAUC_BUNDLE_COMPATIBLE ?= "edge-ai-${MACHINE}"

RAUC_BUNDLE_SLOTS  = "rootfs"
# Default to the dev image — the current iteration target. Operators
# shipping prod bundles set BUNDLE_IMAGE_NAME = "edge-image-prod" (or
# "-base") in kas/local.yml.
BUNDLE_IMAGE_NAME ?= "edge-image-dev"
BUNDLE_IMAGE       = "${BUNDLE_IMAGE_NAME}"

RAUC_SLOT_rootfs           = "${BUNDLE_IMAGE}"
RAUC_SLOT_rootfs[fstype]   = "ext4"
RAUC_SLOT_rootfs[hooks]    = "pre-install;post-install"

# Disable adaptive updates (block-hash-index) by default. Re-enable per-build
# via EDGE_RAUC_ADAPTIVE=1 for smaller bundle transfer at the cost of
# the longer hash-index compute phase.
EDGE_RAUC_ADAPTIVE         ?= "0"
RAUC_SLOT_rootfs[adaptive] = "${@bb.utils.contains('EDGE_RAUC_ADAPTIVE','1','block-hash-index','',d)}"

# Bundle format: verity by default; crypt when encryption is opted-in. The
# device's system.conf [encryption] block must point at a matching key
# (file or pkcs11: URI), wired via EDGE_RAUC_ENCRYPTION_KEY in rauc-conf-edge.
EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "0"
EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS ?= ""
RAUC_BUNDLE_FORMAT = "${@bb.utils.contains('EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION', '1', 'crypt', 'verity', d)}"

# Manifest metadata. bundle.bbclass auto-populates these from PV/SUMMARY/DATETIME
# by default; override so the bundle's [update] section reads correctly on the
# device (rauc status, fleet dashboard).
RAUC_BUNDLE_VERSION     = "${DISTRO_VERSION}"
RAUC_BUNDLE_DESCRIPTION = "EDGE AI OS bundle for ${MACHINE} (image: ${BUNDLE_IMAGE})"
RAUC_BUNDLE_BUILD       = "${EDGE_BUILD_ID}"
RAUC_BUNDLE_BUILD[vardepsexclude] = "EDGE_BUILD_ID DATETIME"

EDGE_RAUC_UPDATE_BOOTFILES         ?= "0"
EDGE_RAUC_BOOTFILES_ARCHIVE_RECIPE ?= "edge-bootfiles-archive"
EDGE_RAUC_BOOTFILES_SOURCE_FILE    ?= "bootfiles.tar.gz"
EDGE_RAUC_BOOTFILES_BUNDLE_FILE    ?= "bootfiles.tar.gz"
EDGE_RAUC_TRACK_DEPLOY_FILES       ?= ""

RAUC_BUNDLE_EXTRA_DEPENDS += "${@bb.utils.contains('EDGE_RAUC_UPDATE_BOOTFILES','1',' ${EDGE_RAUC_BOOTFILES_ARCHIVE_RECIPE}','',d)}"
RAUC_BUNDLE_EXTRA_FILES   += "${@bb.utils.contains('EDGE_RAUC_UPDATE_BOOTFILES','1',' ${EDGE_RAUC_BOOTFILES_BUNDLE_FILE}','',d)}"
RAUC_BUNDLE_HOOKS[file]    = "bundle-hooks.sh"

# Track selected deploy artifacts in the task hash so sstate invalidates
# on content changes.
python __anonymous() {
    deploy_dir = d.getVar("DEPLOY_DIR_IMAGE")
    files = []

    extra = (d.getVar("EDGE_RAUC_TRACK_DEPLOY_FILES") or "").split()
    files.extend(extra)

    if d.getVar("EDGE_RAUC_UPDATE_BOOTFILES") == "1":
        bootfiles = d.getVar("EDGE_RAUC_BOOTFILES_SOURCE_FILE")
        if bootfiles:
            files.append(bootfiles)

    if not files:
        return

    files = list(dict.fromkeys(files))
    checksums = d.getVarFlag("do_configure", "file-checksums") or ""
    entries = [f"{deploy_dir}/{name}:True" for name in files]
    d.setVarFlag("do_configure", "file-checksums", (checksums + " " + " ".join(entries)).strip())
}

# Stage the bootfiles archive into WORKDIR when EDGE_RAUC_UPDATE_BOOTFILES=1.
# Must not use bare `return` — bitbake stitches this prepend body into the
# bbclass do_configure, so an early return would skip write_manifest below.
python do_configure:prepend() {
    if d.getVar("EDGE_RAUC_UPDATE_BOOTFILES") == "1":
        import os, shutil
        src_name = d.getVar("EDGE_RAUC_BOOTFILES_SOURCE_FILE")
        dst_name = d.getVar("EDGE_RAUC_BOOTFILES_BUNDLE_FILE")

        src = os.path.join(d.getVar("DEPLOY_DIR_IMAGE"), src_name)
        dst = os.path.join(d.getVar("WORKDIR"), dst_name)

        if not os.path.isfile(src):
            bb.fatal("Bootfiles source archive not found: %s" % src)

        if src != dst:
            shutil.copyfile(src, dst)
}

# Pick up bundle-hooks.sh from the sibling rauc/files directory.
FILESEXTRAPATHS:prepend := "${THISDIR}/../rauc/files:"
SRC_URI:append = " file://bundle-hooks.sh;mode=0755 "

# Per-board substitution: bundle-hooks.sh ships with @DTB_FILENAME@
# placeholder; EDGE_BOOT_DTB (per kas/machines/<board>.yml) supplies the
# value. Done at unpack so bundle.bbclass picks up the substituted file
# from UNPACKDIR. Failing-loud on empty EDGE_BOOT_DTB prevents shipping
# a bundle whose hook would silently install no DTB.
do_unpack[postfuncs] += "edge_bundle_substitute_dtb"
edge_bundle_substitute_dtb() {
    if [ -z "${EDGE_BOOT_DTB}" ]; then
        bbfatal "EDGE_BOOT_DTB is empty — set it in kas/machines/${MACHINE}.yml"
    fi
    sed -i "s|@DTB_FILENAME@|${EDGE_BOOT_DTB}|g" \
        "${UNPACKDIR}/bundle-hooks.sh"
}

BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME     = "${BUNDLE_BASENAME}"

# Post-bundle encryption pass. When EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION = 1,
# the bundle was built as crypt format (encrypted manifest); this re-runs
# `rauc encrypt` against EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS to add
# recipient-bound AES key wrappings (one per device or per group).
do_bundle:append() {
    if [ "${EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION}" != "1" ]; then
        exit 0
    fi
    if [ -z "${EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}" ]; then
        bbfatal "'EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS' not set while encrypted bundle mode is enabled"
    fi
    if [ ! -f "${EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}" ]; then
        bbfatal "Encrypted bundle recipients file not found: ${EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}"
    fi
    keyring="${RAUC_KEYRING_FILE}"
    if [ -z "${keyring}" ] || [ ! -f "${keyring}" ]; then
        if [ -n "${RAUC_DEVICE_KEYRING}" ] && [ -f "${RAUC_DEVICE_KEYRING}" ]; then
            keyring="${RAUC_DEVICE_KEYRING}"
        else
            bbfatal "Cannot find keyring for rauc encrypt; set RAUC_KEYRING_FILE or RAUC_DEVICE_KEYRING."
        fi
    fi
    ${STAGING_BINDIR_NATIVE}/rauc encrypt \
        --debug \
        --to="${EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}" \
        --keyring="${keyring}" \
        ${B}/bundle.raucb \
        ${B}/encrypted-bundle.raucb
    mv ${B}/encrypted-bundle.raucb ${B}/bundle.raucb
}
