#!/usr/bin/env bash
# Generate a self-signed root CA + leaf signing cert for RAUC bundles.
# Idempotent: re-running is a no-op once the leaf exists.
#
# Output layout (gitignored under keys/):
#   keys/dev/rauc/rauc-ca.key            — root CA private key
#   keys/dev/rauc/rauc-ca.cert.pem       — root CA cert (installed on
#                                          device as /etc/rauc/ca.cert.pem)
#   keys/dev/rauc/rauc-signer.key        — leaf signing private key
#   keys/dev/rauc/rauc-signer.cert.pem   — leaf cert (codeSigning EKU)
#
# Bundle build (from edge-floor.inc) consumes these as:
#   RAUC_KEY_FILE     = .../rauc-signer.key
#   RAUC_CERT_FILE    = .../rauc-signer.cert.pem
#   RAUC_KEYRING_FILE = .../rauc-ca.cert.pem
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

mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

if [ -f "${LEAF_CRT}" ] && [ -f "${LEAF_KEY}" ] && [ -f "${CA_CRT}" ]; then
    echo "RAUC dev keys already present at ${KEY_DIR}; nothing to do."
    echo "Delete the directory to regenerate (note: device CA cert will need re-flashing)."
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

rm -f "${LEAF_CSR}" "${EXT_FILE}" "${KEY_DIR}/rauc-ca.srl"

# --- Sanity check ---------------------------------------------------------

openssl verify -CAfile "${CA_CRT}" "${LEAF_CRT}" >/dev/null

echo "RAUC dev PKI generated:"
echo "  CA:     ${CA_CRT}"
echo "  Signer: ${LEAF_CRT}"
echo "  Leaf EKU: $(openssl x509 -in "${LEAF_CRT}" -noout -ext extendedKeyUsage 2>/dev/null | tail -1 | tr -d ' ')"
