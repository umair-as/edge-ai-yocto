SUMMARY     = "OTA mTLS user + directory layout for the edge distro"
DESCRIPTION = "Creates the unprivileged 'ota' system user, the /etc/ota \
directory layout, and (optionally) seeds a dev mTLS cert chain from the \
host. The full per-device provisioning + PKCS#11 + TPM2 helpers can be \
layered on later — this recipe is the floor: it makes the file refs in \
rauc-conf-edge's [streaming] block valid so RAUC parses system.conf cleanly \
even when the OTA streaming server is not yet wired."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch useradd

# Optional: dev CA cert dir to seed /etc/ota with. When set, files
# ca.crt + device.crt + device.key are pulled from this directory at
# build time. Leave unset to ship only the empty layout.
EDGE_OTA_CERT_DIR ?= ""

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
}

FILES:${PN} = " \
    ${sysconfdir}/ota \
    ${sysconfdir}/ota/* \
"

# Allow files to be missing when EDGE_OTA_CERT_DIR is unset.
ALLOW_EMPTY:${PN} = "1"
