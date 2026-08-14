SUMMARY     = "RAUC system configuration for the edge A/B update flow"
DESCRIPTION = "Renders /etc/rauc/system.conf from a template with toggle-driven \
keyring mode (single-cert path vs. multi-cert directory), optional codeSigning \
purpose enforcement, allowed-signer CN allowlist, optional encrypted-bundle \
support, and a PKCS#11 streaming TLS key URI."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

RPROVIDES:${PN} += "virtual-rauc-conf"
INHIBIT_DEFAULT_DEPS = "1"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://system.conf \
    file://ca.cert.pem \
"

S = "${UNPACKDIR}"

# Single source of truth: bundle recipe must use exactly this same value.
# Compatible is locked at edge-ai-<machine>; any future rename forces
# RAUC `--ignore-compatible` on every deployed device.
RAUC_BUNDLE_COMPATIBLE ?= "edge-ai-${MACHINE}"

# ----- mTLS streaming TLS key -------------------------------------------
# Default file mode: /etc/ota/device.key (provisioned by ota-certs).
# PKCS#11 mode: operator sets EDGE_RAUC_STREAMING_KEY_MODE = "pkcs11"
# and EDGE_RAUC_PKCS11_TLS_KEY to a pkcs11: URI in kas/local.yml.
EDGE_RAUC_STREAMING_KEY_MODE ?= "file"
EDGE_RAUC_PKCS11_TLS_KEY     ?= ""
EDGE_RAUC_STREAMING_TLS_KEY   = "${@bb.utils.contains('EDGE_RAUC_STREAMING_KEY_MODE', 'pkcs11', d.getVar('EDGE_RAUC_PKCS11_TLS_KEY') or '', '/etc/ota/device.key', d)}"

# ----- Bundle signing PKI hygiene ---------------------------------------
# EDGE_RAUC_KEYRING_CERTS: space-separated list of cert files installed
#   into /etc/rauc/keyring.d/ and hashed via `openssl rehash`. When set the
#   [keyring] stanza renders as `directory=/etc/rauc/keyring.d/` so multiple
#   trust anchors can be enumerated (dual-root keyring, transition window
#   with legacy + new certs). When empty the legacy single-cert form
#   (path=/etc/rauc/ca.cert.pem) is used and the cert comes from
#   RAUC_DEVICE_KEYRING / RAUC_CERT_FILE.
# EDGE_RAUC_ALLOWED_SIGNER_CNS: semicolon-separated CN allowlist. Empty =
#   no restriction (dev). Set on prod images to fence off legacy / dev leaves.
# EDGE_RAUC_CHECK_PURPOSE: OpenSSL X.509 purpose enforced on the signer
#   chain (e.g. "codesign"). Our own rauc-init-certs.sh emits a codeSigning
#   EKU so "codesign" is the safe default.
EDGE_RAUC_KEYRING_CERTS       ?= ""
EDGE_RAUC_ALLOWED_SIGNER_CNS  ?= ""
EDGE_RAUC_CHECK_PURPOSE       ?= "codesign"

# ----- Bundle encryption (crypt format) ---------------------------------
EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "0"
EDGE_RAUC_ENCRYPTION_KEY  ?= ""
EDGE_RAUC_ENCRYPTION_CERT ?= ""

do_install() {
    install -d ${D}${sysconfdir}/rauc

    sed -e "s|@COMPATIBLE@|${RAUC_BUNDLE_COMPATIBLE}|g" \
        -e "s|@TLS_KEY@|${EDGE_RAUC_STREAMING_TLS_KEY}|g" \
        ${UNPACKDIR}/system.conf > ${D}${sysconfdir}/rauc/system.conf

    # Keyring locator: directory mode (multi-cert + hashed dir) when
    # EDGE_RAUC_KEYRING_CERTS is set, else legacy single-cert path mode.
    if [ -n "${EDGE_RAUC_KEYRING_CERTS}" ]; then
        sed -i "s|@RAUC_KEYRING_LOCATOR@|directory=/etc/rauc/keyring.d/|g" \
            ${D}${sysconfdir}/rauc/system.conf
    else
        sed -i "s|@RAUC_KEYRING_LOCATOR@|path=/etc/rauc/ca.cert.pem|g" \
            ${D}${sysconfdir}/rauc/system.conf
    fi

    # check-purpose: render the directive when non-empty, otherwise drop the line.
    if [ -n "${EDGE_RAUC_CHECK_PURPOSE}" ]; then
        sed -i "s|@RAUC_CHECK_PURPOSE_STANZA@|check-purpose=${EDGE_RAUC_CHECK_PURPOSE}|g" \
            ${D}${sysconfdir}/rauc/system.conf
    else
        sed -i "/@RAUC_CHECK_PURPOSE_STANZA@/d" \
            ${D}${sysconfdir}/rauc/system.conf
    fi

    # allowed-signer-cns: render only when non-empty.
    if [ -n "${EDGE_RAUC_ALLOWED_SIGNER_CNS}" ]; then
        sed -i "s|@RAUC_ALLOWED_SIGNER_CNS_STANZA@|allowed-signer-cns=${EDGE_RAUC_ALLOWED_SIGNER_CNS}|g" \
            ${D}${sysconfdir}/rauc/system.conf
    else
        sed -i "/@RAUC_ALLOWED_SIGNER_CNS_STANZA@/d" \
            ${D}${sysconfdir}/rauc/system.conf
    fi

    # Encryption: append [encryption] block when opt-in flag is on.
    if [ "${EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION}" = "1" ]; then
        if [ -z "${EDGE_RAUC_ENCRYPTION_KEY}" ]; then
            bbfatal "EDGE_RAUC_ENCRYPTION_KEY is required when encrypted bundle mode is enabled."
        fi
        {
            echo ""
            echo "[encryption]"
            echo "key=${EDGE_RAUC_ENCRYPTION_KEY}"
            if [ -n "${EDGE_RAUC_ENCRYPTION_CERT}" ]; then
                echo "cert=${EDGE_RAUC_ENCRYPTION_CERT}"
            fi
        } >> ${D}${sysconfdir}/rauc/system.conf
    fi

    # Device keyring deployment.
    # Directory mode: install each cert from EDGE_RAUC_KEYRING_CERTS into
    # /etc/rauc/keyring.d/ and produce OpenSSL hash-dir entries via
    # `openssl rehash`. Path mode: install a single cert as
    # /etc/rauc/ca.cert.pem (dev / legacy).
    if [ -n "${EDGE_RAUC_KEYRING_CERTS}" ]; then
        install -d ${D}${sysconfdir}/rauc/keyring.d
        for cert in ${EDGE_RAUC_KEYRING_CERTS}; do
            if [ ! -f "$cert" ]; then
                bbfatal "Keyring directory entry not found: $cert"
            fi
            install -m 0644 "$cert" ${D}${sysconfdir}/rauc/keyring.d/
        done
        if ! command -v openssl >/dev/null 2>&1; then
            bbfatal "openssl required on the build host to rehash /etc/rauc/keyring.d/."
        fi
        openssl rehash ${D}${sysconfdir}/rauc/keyring.d/ >/dev/null
    else
        keyring="${RAUC_DEVICE_KEYRING}"
        if [ -z "$keyring" ]; then
            keyring="${RAUC_CERT_FILE}"
        fi
        if [ -n "$keyring" ] && [ -f "$keyring" ]; then
            install -m 0644 "$keyring" ${D}${sysconfdir}/rauc/ca.cert.pem
        else
            echo "WARNING: Using fallback placeholder RAUC keyring. Configure RAUC_DEVICE_KEYRING for production OTA." >&2
            install -m 0644 ${UNPACKDIR}/ca.cert.pem ${D}${sysconfdir}/rauc/ca.cert.pem
        fi
    fi
}

FILES:${PN} = " \
    ${sysconfdir}/rauc/system.conf \
    ${sysconfdir}/rauc/ca.cert.pem \
    ${sysconfdir}/rauc/keyring.d \
    ${sysconfdir}/rauc/keyring.d/* \
"

# ota-certs creates the unprivileged 'ota' user (referenced by [streaming]
# sandbox-user) and the /etc/ota directory layout so system.conf parses
# cleanly even when an OTA streaming server isn't wired yet.
RDEPENDS:${PN} += "ota-certs"
