LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit bundle

# Single source of truth: must match rauc-conf-edge byte-for-byte.
RAUC_BUNDLE_COMPATIBLE ?= "edge-ai-${MACHINE}"

RAUC_BUNDLE_SLOTS  = "rootfs"
# Default to the dev image — the current iteration target. Operators
# shipping prod bundles set BUNDLE_IMAGE_NAME = "edge-image-prod" (or
# "-base") in kas/local.yml.
BUNDLE_IMAGE_NAME ?= "edge-image-dev"
BUNDLE_IMAGE       = "${BUNDLE_IMAGE_NAME}"

RAUC_SLOT_rootfs           = "${BUNDLE_IMAGE}"
RAUC_SLOT_rootfs[fstype]   = "ext4.verity"
RAUC_SLOT_rootfs[imagetype] = "raw"
RAUC_SLOT_rootfs[hooks]    = "pre-install;post-install"

# Disable adaptive updates (block-hash-index) by default. Re-enable per-build
# via EDGE_RAUC_ADAPTIVE=1 for smaller bundle transfer at the cost of
# the longer hash-index compute phase.
EDGE_RAUC_ADAPTIVE         ?= "0"
RAUC_SLOT_rootfs[adaptive] = "${@bb.utils.contains('EDGE_RAUC_ADAPTIVE','1','block-hash-index','',d)}"

# Bundle format: crypt by default distro-wide (edge-features.inc), verity
# only when encryption is explicitly overridden off. The device's
# system.conf [encryption] block must point at a matching key (file or
# pkcs11: URI), wired via EDGE_RAUC_ENCRYPTION_KEY in rauc-conf-edge, and
# its bundle-formats allowlist must include crypt or the install is
# refused. Both are rendered by rauc-conf-edge off the same toggle.
#
# RAUC_BUNDLE_FORMAT is singular: one build emits one format. An explicit
# EDGE_RAUC_BUNDLE_FORMAT = "verity" override exists for the first step of
# an encrypted rollout to an already-fielded pre-crypt device, where the
# image must already be encryption-ready but the bundle delivering it must
# still be verity, because that device does not yet accept crypt. A fresh
# flash of a crypt-default image needs no such step.
#
# The "0" below is only the recipe-local fallback if this recipe is ever
# parsed outside the edge-features.inc distro config.
EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "0"
EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS ?= ""
# Same expression as edge-features.inc's global default, which is what
# actually applies in this distro; this line is only the standalone-recipe
# fallback and, more importantly, a same-file reminder of the derivation
# next to where RAUC_BUNDLE_FORMAT below consumes it.
EDGE_RAUC_BUNDLE_FORMAT ?= "${@bb.utils.contains('EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION', '1', 'crypt', 'verity', d)}"
RAUC_BUNDLE_FORMAT = "${EDGE_RAUC_BUNDLE_FORMAT}"

# Manifest metadata. bundle.bbclass auto-populates these from PV/SUMMARY/DATETIME
# by default; override so the bundle's [update] section reads correctly on the
# device (rauc status, fleet dashboard).
RAUC_BUNDLE_VERSION     = "${DISTRO_VERSION}"
RAUC_BUNDLE_DESCRIPTION = "EDGE AI OS bundle for ${MACHINE} (image: ${BUNDLE_IMAGE})"
RAUC_BUNDLE_BUILD       = "${EDGE_BUILD_ID}"
RAUC_BUNDLE_BUILD[vardepsexclude] = "EDGE_BUILD_ID DATETIME"

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
SRC_URI:append = " file://bundle-hooks.sh;mode=0755 file://rauc-uboot-env.defaults "
RAUC_BUNDLE_EXTRA_FILES += "rauc-uboot-env.defaults"

# Substitute image-specific bundle filenames before bundle.bbclass copies the
# hook. Slot selection remains a runtime RAUC decision.
do_unpack[postfuncs] += "edge_bundle_substitute_fit_names"
edge_bundle_substitute_fit_names() {
    sed -i \
        -e "s|@FIT_IMAGE_A@|${EDGE_RAUC_FIT_A}|g" \
        -e "s|@FIT_IMAGE_B@|${EDGE_RAUC_FIT_B}|g" \
        "${UNPACKDIR}/bundle-hooks.sh"
}

BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME     = "${BUNDLE_BASENAME}"

# Post-bundle encryption pass. `rauc bundle --format=crypt` leaves the
# payload AES key in a cleartext manifest; `rauc encrypt` CMS-envelopes that
# manifest to the recipient certs. The result replaces bundle.raucb in place
# rather than deploying alongside it (bundle.bbclass' RAUC_ENCRYPT_CRYPT_BUNDLE
# path), so the key-bearing intermediate never reaches DEPLOY_DIR_IMAGE.
#
# The gate is the emitted format, not the toggle: `rauc encrypt` refuses an
# input bundle that is not already 'crypt', so the transition build (encryption
# enabled, format pinned to verity) must skip this pass entirely.
#
# Recipient rotation must invalidate the task; the PEM is not in SRC_URI, so
# hash it explicitly. A ":False" entry is dropped by bb.checksum without being
# read, so the entry is emitted only when this build actually encrypts.
do_bundle[file-checksums] += "${@d.getVar('EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS') + ':True' if d.getVar('RAUC_BUNDLE_FORMAT') == 'crypt' and d.getVar('EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS') else ''}"
do_bundle:append() {
    if [ "${RAUC_BUNDLE_FORMAT}" != "crypt" ]; then
        if [ "${EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION}" = "1" ]; then
            bbnote "Bundle encryption is enabled but the bundle format is '${RAUC_BUNDLE_FORMAT}': emitting an unencrypted bundle carrying the encryption-ready image."
        fi
        return 0
    fi
    if [ -z "${EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}" ]; then
        bbfatal "'EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS' not set while encrypted bundle mode is enabled"
    fi
    if [ ! -f "${EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}" ]; then
        bbfatal "Encrypted bundle recipients file not found: ${EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}. Run scripts/rauc-init-certs.sh to generate the dev recipient keypair."
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
