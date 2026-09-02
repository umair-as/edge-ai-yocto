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
#   keys/dev/rauc/rauc-signer.cert.pem       — leaf cert (codeSigning EKU)
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

if [ -f "${LEAF_CRT}" ] && [ -f "${LEAF_KEY}" ] && [ -f "${CA_CRT}" ] \
   && [ -f "${RCPT_CRT}" ] && [ -f "${RCPT_KEY}" ] && [ -f "${RCPT_PEM}" ]; then
    echo "RAUC dev keys already present at ${KEY_DIR}; nothing to do."
    echo "Delete the directory to regenerate (note: device CA cert and bundle"
    echo "decryption key will need re-flashing)."
    exit 0
fi

echo "Generating RAUC dev PKI in ${KEY_DIR}"

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

    # Extensions for the leaf: codeSigning EKU + non-CA
    cat > "${EXT_FILE}" <<EOF
basicConstraints = CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
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
# for the dev flow; a fleet concatenates one cert per device or group.
if [ ! -f "${RCPT_PEM}" ]; then
    cat "${RCPT_CRT}" > "${RCPT_PEM}"
    chmod 644 "${RCPT_PEM}"
fi

# --- Sanity check ---------------------------------------------------------

openssl verify -CAfile "${CA_CRT}" "${LEAF_CRT}" >/dev/null

# The recipient key and cert must pair, or `rauc install` fails on the device
# with no usable recipient rather than at build time.
rcpt_key_mod="$(openssl rsa -in "${RCPT_KEY}" -noout -modulus)"
rcpt_crt_mod="$(openssl x509 -in "${RCPT_CRT}" -noout -modulus)"
if [ "${rcpt_key_mod}" != "${rcpt_crt_mod}" ]; then
    echo "ERROR: ${RCPT_KEY} does not match ${RCPT_CRT}" >&2
    exit 1
fi

echo "RAUC dev PKI generated:"
echo "  CA:         ${CA_CRT}"
echo "  Signer:     ${LEAF_CRT}"
echo "  Leaf EKU:   $(openssl x509 -in "${LEAF_CRT}" -noout -ext extendedKeyUsage 2>/dev/null | tail -1 | tr -d ' ')"
echo "  Recipient:  ${RCPT_CRT}"
echo "  Device key: ${RCPT_KEY}  (installed as /etc/ota/bundle-decrypt.key)"
echo "  Recipients: ${RCPT_PEM}  (rauc encrypt --to)"
