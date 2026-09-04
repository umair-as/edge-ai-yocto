#!/usr/bin/env bash
# Generate the RAUC dev PKI: a self-signed root CA + leaf signing cert for
# bundle signatures, and a recipient keypair for crypt-format bundles.
# Idempotent: each artifact is generated only when absent.
#
# Output layout (gitignored under keys/):
#   keys/dev/rauc/rauc-ca.key                — root CA private key
#   keys/dev/rauc/rauc-ca.cert.pem           — root CA cert (installed on
#                                              device as /etc/rauc/ca.cert.pem)
#   keys/dev/rauc/rauc-signer.key            — leaf signing private key
#   keys/dev/rauc/rauc-signer.cert.pem       — leaf cert (codeSigning +
#                                              emailProtection EKU)
#   keys/dev/rauc/rauc-recipient.key         — bundle decryption private key
#   keys/dev/rauc/rauc-recipient.cert.pem    — matching recipient cert
#   keys/dev/rauc/rauc-recipients.pem        — `rauc encrypt --to` input:
#                                              concatenated recipient certs
#
# Bundle build (from edge-floor.inc) consumes these as:
#   RAUC_KEY_FILE                       = .../rauc-signer.key
#   RAUC_CERT_FILE                      = .../rauc-signer.cert.pem
#   RAUC_KEYRING_FILE                   = .../rauc-ca.cert.pem
#   EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS = .../rauc-recipients.pem
#   EDGE_RAUC_DECRYPT_KEY_SRC           = .../rauc-recipient.key
#   EDGE_RAUC_DECRYPT_CERT_SRC          = .../rauc-recipient.cert.pem
#
# The recipient cert is self-signed and deliberately outside the signing
# chain: RAUC verifies bundle signatures against the keyring and resolves
# recipients by certificate identity, so the two PKIs are independent. An
# empty EDGE_RAUC_DECRYPT_KEY_SRC leaves the device key to a PKCS#11 token,
# in which case the recipient files here are unused.
#
# Validity is 10 years — these are dev keys; prod will use a different
# PKI rooted in an HSM-backed CA.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_DIR="${REPO_ROOT}/keys/dev/rauc"

CA_KEY="${KEY_DIR}/rauc-ca.key"
CA_CRT="${KEY_DIR}/rauc-ca.cert.pem"
LEAF_KEY="${KEY_DIR}/rauc-signer.key"
LEAF_CRT="${KEY_DIR}/rauc-signer.cert.pem"
LEAF_CSR="${KEY_DIR}/rauc-signer.csr"
EXT_FILE="${KEY_DIR}/rauc-signer.ext"

RCPT_KEY="${KEY_DIR}/rauc-recipient.key"
RCPT_CRT="${KEY_DIR}/rauc-recipient.cert.pem"
RCPT_PEM="${KEY_DIR}/rauc-recipients.pem"

mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

# True if $1 (a PEM file, possibly holding more than one certificate --
# rauc-recipients.pem's multi-recipient rotation-overlap form) contains a
# certificate whose SHA-256 fingerprint matches $2. Portable pure
# bash+openssl split, no csplit/mktemp: a `rauc encrypt --to` PEM is always
# a plain concatenation of individual certs.
pem_contains_cert() {
    local pem="$1" cert="$2" want block="" in_cert=0
    [ -f "${pem}" ] || return 1
    want="$(openssl x509 -in "${cert}" -noout -fingerprint -sha256)"
    while IFS= read -r line; do
        if [ "${line}" = "-----BEGIN CERTIFICATE-----" ]; then
            in_cert=1
            block="${line}"$'\n'
            continue
        fi
        [ "${in_cert}" = "1" ] || continue
        block="${block}${line}"$'\n'
        if [ "${line}" = "-----END CERTIFICATE-----" ]; then
            in_cert=0
            if [ "$(printf '%s' "${block}" | openssl x509 -in - -noout -fingerprint -sha256 2>/dev/null)" = "${want}" ]; then
                return 0
            fi
        fi
    done < "${pem}"
    return 1
}

# Deliberately does not exit early when every file is present: a partial
# deletion (e.g. only rauc-signer.key removed) regenerates just that one
# artifact below and must still reach the pairing checks near the end of
# this script, and an already-complete but silently mismatched set (any
# cause — manual copy, a previous run of a buggy version of this script)
# must be caught on every invocation, not only when something was missing.
if [ -f "${LEAF_CRT}" ] && [ -f "${LEAF_KEY}" ] && [ -f "${CA_CRT}" ] \
   && [ -f "${RCPT_CRT}" ] && [ -f "${RCPT_KEY}" ] && [ -f "${RCPT_PEM}" ]; then
    echo "RAUC dev keys already present at ${KEY_DIR}; verifying pairing."
    echo "Delete the directory to regenerate (note: device CA cert and bundle"
    echo "decryption key will need re-flashing)."
else
    echo "Generating RAUC dev PKI in ${KEY_DIR}"
fi

# --- Root CA ---------------------------------------------------------------

if [ ! -f "${CA_KEY}" ]; then
    openssl genrsa -out "${CA_KEY}" 4096
    chmod 600 "${CA_KEY}"
fi

if [ ! -f "${CA_CRT}" ]; then
    openssl req -x509 -new -nodes \
        -key "${CA_KEY}" \
        -sha256 -days 3650 \
        -subj "/O=edge-ai-yocto/CN=edge-ai-rauc-dev-ca" \
        -addext "basicConstraints=critical,CA:true" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "${CA_CRT}"
fi

# --- Leaf signing cert ----------------------------------------------------

if [ ! -f "${LEAF_KEY}" ]; then
    openssl genrsa -out "${LEAF_KEY}" 4096
    chmod 600 "${LEAF_KEY}"
fi

if [ ! -f "${LEAF_CRT}" ]; then
    # CSR
    openssl req -new \
        -key "${LEAF_KEY}" \
        -subj "/O=edge-ai-yocto/CN=edge-ai-rauc-dev-signer" \
        -out "${LEAF_CSR}"

    # Extensions for the leaf: non-CA, codeSigning (the on-device
    # check-purpose=codesign gate) plus emailProtection. `rauc encrypt`
    # re-verifies its own output bundle's signature via a CLI path that
    # loads no system.conf (R_CONTEXT_CONFIG_MODE_NONE in rauc's main.c),
    # so it falls through to OpenSSL's CMS_verify default purpose check
    # (S/MIME signing). That check requires emailProtection in the EKU, or
    # no EKU at all — NOT anyExtendedKeyUsage, which OpenSSL's xku_reject
    # does not treat as satisfying the S/MIME-sign purpose (measured on
    # 3.0.13 and 3.5.7: codeSigning+anyExtendedKeyUsage still fails). A
    # codeSigning-only leaf fails the self-check with "unsuitable
    # certificate purpose" and every crypt-format do_bundle aborts;
    # emailProtection satisfies it without loosening the on-device
    # codesign requirement (RAUC's custom codesign purpose only checks that
    # codeSigning is present, not that it is exclusive).
    cat > "${EXT_FILE}" <<EOF
basicConstraints = CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning,emailProtection
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

    openssl x509 -req \
        -in "${LEAF_CSR}" \
        -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
        -sha256 -days 3650 \
        -extfile "${EXT_FILE}" \
        -out "${LEAF_CRT}"

    # -CAcreateserial names the serial file after the -CA argument with the
    # extension swapped, i.e. rauc-ca.cert.srl.
    rm -f "${LEAF_CSR}" "${EXT_FILE}" "${KEY_DIR}/rauc-ca.cert.srl"
fi

# --- Bundle encryption recipient ------------------------------------------

# Self-signed: recipient identity is independent of the signing chain above.
# keyEncipherment + dataEncipherment are what CMS EnvelopedData needs to wrap
# the payload key to an RSA recipient.
if [ ! -f "${RCPT_KEY}" ]; then
    openssl genrsa -out "${RCPT_KEY}" 4096
    chmod 600 "${RCPT_KEY}"
fi

if [ ! -f "${RCPT_CRT}" ]; then
    openssl req -x509 -new -nodes \
        -key "${RCPT_KEY}" \
        -sha256 -days 3650 \
        -subj "/O=edge-ai-yocto/CN=edge-ai-rauc-dev-recipient" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,keyEncipherment,dataEncipherment" \
        -addext "subjectKeyIdentifier=hash" \
        -out "${RCPT_CRT}"
fi

# `rauc encrypt --to` takes a PEM bundle of every recipient cert. One entry
# for the dev flow; a fleet concatenates one cert per device or group by
# hand (this script only ever emits a single-cert PEM). Checked by content
# (pem_contains_cert), not by "did this run just regenerate RCPT_CRT": an
# earlier version of this check keyed on the latter and so never repaired a
# PEM left stale by a run of the pre-fix script -- it only refreshed a PEM
# it had itself just gone stale in the same invocation, missing the actual
# migration case the fix was for. A PEM whose current entry does not match
# RCPT_CRT is exactly the case where `rauc encrypt` would keep encrypting
# to a cert no device holds, surfacing only on-device at install time ("no
# usable recipient"), after the bundle has already been published. If this
# overwrites a PEM that held more than the current recipient cert (a
# manually assembled multi-recipient rotation window), say so instead of
# silently dropping the other entries.
if [ ! -f "${RCPT_PEM}" ] || ! pem_contains_cert "${RCPT_PEM}" "${RCPT_CRT}"; then
    if [ -f "${RCPT_PEM}" ] && [ "$(grep -c '^-----BEGIN CERTIFICATE-----' "${RCPT_PEM}")" -gt 1 ]; then
        echo "WARNING: ${RCPT_PEM} held more than one recipient certificate;" >&2
        echo "         regenerating rauc-recipient.cert.pem overwrites it with a" >&2
        echo "         single-cert PEM. Re-add any other recipients by hand." >&2
    fi
    cat "${RCPT_CRT}" > "${RCPT_PEM}"
    chmod 644 "${RCPT_PEM}"
fi

# --- Sanity check ---------------------------------------------------------

# The CA pair itself had no modulus check, unlike the signer and recipient
# pairs below -- a deleted-then-regenerated CA_KEY with CA_CRT left in place
# printed "pairing verified" over a broken CA. Not silently dangerous (the
# next leaf issuance below would fail loudly: `openssl x509 -req` refuses to
# sign against a CA cert whose key doesn't match), but the success banner at
# the end of this script should not overclaim.
ca_key_mod="$(openssl rsa -in "${CA_KEY}" -noout -modulus)"
ca_crt_mod="$(openssl x509 -in "${CA_CRT}" -noout -modulus)"
if [ "${ca_key_mod}" != "${ca_crt_mod}" ]; then
    echo "ERROR: ${CA_KEY} does not match ${CA_CRT}" >&2
    exit 1
fi

openssl verify -CAfile "${CA_CRT}" "${LEAF_CRT}" >/dev/null

# Chain verification alone does not catch a mismatched signer pair: a
# partial deletion (only rauc-signer.key removed, say) regenerates the key
# above while the existing cert is left alone, so the CA-chain check still
# passes on the old cert even though it no longer matches the new key. Every
# bundle built with that pair would sign successfully (openssl does not
# check key/cert pairing at sign time) and fail on-device instead.
leaf_key_mod="$(openssl rsa -in "${LEAF_KEY}" -noout -modulus)"
leaf_crt_mod="$(openssl x509 -in "${LEAF_CRT}" -noout -modulus)"
if [ "${leaf_key_mod}" != "${leaf_crt_mod}" ]; then
    echo "ERROR: ${LEAF_KEY} does not match ${LEAF_CRT}" >&2
    exit 1
fi

# The recipient key and cert must pair, or `rauc install` fails on the device
# with no usable recipient rather than at build time.
rcpt_key_mod="$(openssl rsa -in "${RCPT_KEY}" -noout -modulus)"
rcpt_crt_mod="$(openssl x509 -in "${RCPT_CRT}" -noout -modulus)"
if [ "${rcpt_key_mod}" != "${rcpt_crt_mod}" ]; then
    echo "ERROR: ${RCPT_KEY} does not match ${RCPT_CRT}" >&2
    exit 1
fi

echo "RAUC dev PKI (pairing verified):"
echo "  CA:         ${CA_CRT}"
echo "  Signer:     ${LEAF_CRT}"
echo "  Leaf EKU:   $(openssl x509 -in "${LEAF_CRT}" -noout -ext extendedKeyUsage 2>/dev/null | tail -1 | tr -d ' ')"
echo "  Recipient:  ${RCPT_CRT}"
echo "  Device key: ${RCPT_KEY}  (installed as /etc/ota/bundle-decrypt.key)"
echo "  Recipients: ${RCPT_PEM}  (rauc encrypt --to)"
