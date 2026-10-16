#!/usr/bin/env bash
# Generate the dev kernel module signing key: one PEM holding the private key
# and its self-signed X.509 cert, the form CONFIG_MODULE_SIG_KEY expects.
# Idempotent: an existing key is never replaced, because every kernel and
# out-of-tree module built so far is signed with it.
#
# Output (gitignored under keys/):
#   keys/dev/kernel/module-signing.pem   EDGE_MODULE_SIG_KEY in edge-floor.inc
#
# Extensions match the kernel's certs/default_x509.genkey. Dev key only; a
# release kernel signs with a key held outside the build host.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${REPO_ROOT}/keys/dev/kernel/module-signing.pem"

if [ -f "$KEY" ]; then
    echo "module signing key present: $KEY"
    exit 0
fi

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
mkdir -p "$(dirname "$KEY")"
chmod 0700 "$(dirname "$KEY")"

cfg=$(mktemp)
tmp=$(mktemp "$(dirname "$KEY")/.module-signing.XXXXXX")
trap 'rm -f "$cfg" "$tmp"' EXIT
cat > "$cfg" <<'CFG'
[ req ]
default_bits = 4096
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = myexts

[ req_distinguished_name ]
CN = edge-ai dev kernel module signing key

[ myexts ]
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
CFG

openssl req -new -nodes -utf8 -sha512 -days 36500 -batch -x509 \
    -config "$cfg" -outform PEM -out "$tmp" -keyout "$tmp" 2>/dev/null
chmod 0600 "$tmp"
mv "$tmp" "$KEY"
echo "generated module signing key: $KEY"
openssl x509 -in "$KEY" -noout -serial -subject
