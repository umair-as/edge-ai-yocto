# Bundle format and the post-bundle `rauc encrypt` pass, shared by every
# bundle recipe so all follow the same format toggle. Requires
# `inherit bundle` before it.

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
