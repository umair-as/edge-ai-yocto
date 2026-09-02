SUMMARY     = "OTA credential user + directory layout for the edge distro"
DESCRIPTION = "Creates the unprivileged 'ota' system user, the /etc/ota \
directory layout, and (optionally) seeds dev OTA key material from the \
host: the mTLS chain and the RAUC crypt-bundle recipient key. Makes the \
file refs in rauc-conf-edge's [streaming] and [encryption] blocks resolve."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch useradd

# Optional: dev CA cert dir to seed /etc/ota with. When set, files
# ca.crt + device.crt + device.key are pulled from this directory at
# build time. Leave unset to ship only the empty layout.
EDGE_OTA_CERT_DIR ?= ""

# RAUC crypt-bundle recipient key material, copied from the build host into
# the same credential store. Installed only when bundle encryption is on;
# empty source means the device key is expected elsewhere (PKCS#11 token,
# first-boot provisioning). The install paths below are the literals
# rauc-conf-edge renders into the [encryption] stanza; the two must match.
EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "0"
EDGE_RAUC_DECRYPT_KEY_SRC  ?= ""
EDGE_RAUC_DECRYPT_CERT_SRC ?= ""

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r ota"
USERADD_PARAM:${PN} = "--system --gid ota --home /nonexistent --no-create-home --shell /bin/false --comment 'OTA mTLS user' ota"

do_install() {
    install -d -m 0755 -o root -g ota ${D}${sysconfdir}/ota

    if [ -n "${EDGE_OTA_CERT_DIR}" ]; then
        if [ ! -d "${EDGE_OTA_CERT_DIR}" ]; then
            bbfatal "EDGE_OTA_CERT_DIR set but directory not found: ${EDGE_OTA_CERT_DIR}"
        fi
        for f in ca.crt device.crt; do
            if [ -f "${EDGE_OTA_CERT_DIR}/$f" ]; then
                install -m 0644 -o root -g ota \
                    "${EDGE_OTA_CERT_DIR}/$f" \
                    ${D}${sysconfdir}/ota/$f
            fi
        done
        if [ -f "${EDGE_OTA_CERT_DIR}/device.key" ]; then
            install -m 0640 -o root -g ota \
                "${EDGE_OTA_CERT_DIR}/device.key" \
                ${D}${sysconfdir}/ota/device.key
        fi
    fi

    if [ "${EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION}" = "1" ]; then
        if [ -n "${EDGE_RAUC_DECRYPT_KEY_SRC}" ]; then
            if [ ! -f "${EDGE_RAUC_DECRYPT_KEY_SRC}" ]; then
                bbfatal "EDGE_RAUC_DECRYPT_KEY_SRC set but file not found: ${EDGE_RAUC_DECRYPT_KEY_SRC}. Run scripts/rauc-init-certs.sh to generate the dev recipient keypair."
            fi
            install -m 0640 -o root -g ota \
                "${EDGE_RAUC_DECRYPT_KEY_SRC}" \
                ${D}${sysconfdir}/ota/bundle-decrypt.key
        fi

        # Independent of the key: rauc-conf-edge renders cert= from
        # EDGE_RAUC_DECRYPT_CERT_SRC alone, and a PKCS#11-resident key still
        # pairs with a file cert. Nesting this under the key branch leaves
        # cert= naming a file no build installs.
        if [ -n "${EDGE_RAUC_DECRYPT_CERT_SRC}" ]; then
            if [ ! -f "${EDGE_RAUC_DECRYPT_CERT_SRC}" ]; then
                bbfatal "EDGE_RAUC_DECRYPT_CERT_SRC set but file not found: ${EDGE_RAUC_DECRYPT_CERT_SRC}"
            fi
            install -m 0644 -o root -g ota \
                "${EDGE_RAUC_DECRYPT_CERT_SRC}" \
                ${D}${sysconfdir}/ota/bundle-decrypt.cert.pem
        fi
    fi
}

# Host-side key material is outside SRC_URI, so its content is not otherwise
# in the task signature; without this a key rotation restores a stale package
# from sstate. A ":False" entry is dropped by bb.checksum without being read,
# so entries are emitted only for the files this build actually installs.
EDGE_RAUC_DECRYPT_CHECKSUMS = "${@' '.join(p + ':True' for p in (d.getVar('EDGE_RAUC_DECRYPT_KEY_SRC'), d.getVar('EDGE_RAUC_DECRYPT_CERT_SRC')) if p) if d.getVar('EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION') == '1' else ''}"
do_install[file-checksums] += "${EDGE_RAUC_DECRYPT_CHECKSUMS}"

FILES:${PN} = " \
    ${sysconfdir}/ota \
    ${sysconfdir}/ota/* \
"

# Allow files to be missing when EDGE_OTA_CERT_DIR is unset.
ALLOW_EMPTY:${PN} = "1"
