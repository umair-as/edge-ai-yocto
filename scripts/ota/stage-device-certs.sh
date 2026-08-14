#!/usr/bin/env bash
# Stage an mTLS device identity for EDGE_OTA_CERT_DIR, with validation.
#
# The OTA server mints device certs under its own naming
# (certs/devices/<device-id>.{crt,key}) alongside certs/ca.crt. The
# ota-certs recipe consumes exactly three files from one directory:
#
#   <stage-dir>/ca.crt       — CA that signed the server cert (0644)
#   <stage-dir>/device.crt   — this device's client cert       (0644)
#   <stage-dir>/device.key   — this device's private key       (0600)
#
# This script assembles that directory and refuses to do so if the material
# would not actually authenticate: wrong key for the cert, a chain that does
# not verify against the CA, or an expired cert. Those failures are silent at
# build time — the image builds, ships a live [streaming] block, and only
# fails at `rauc install` against a TLS error.
#
# The staging directory holds an unencrypted private key. It must live
# OUTSIDE the repo; the script refuses in-repo destinations rather than
# relying on .gitignore and the forbid-private-keys commit hook.
#
# Usage:
#   scripts/ota/stage-device-certs.sh \
#       --ca      <ca.crt> \
#       --cert    <device-id.crt> \
#       --key     <device-id.key> \
#       [--out    <stage-dir>]     # default: ~/.edge-ota/<cert-CN>
#
# Then, in kas/local.yml:
#   EDGE_OTA_CERT_DIR = "<stage-dir>"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

CA=""; CERT=""; KEY=""; OUT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ca)   CA="${2:?--ca needs a path}"; shift 2 ;;
        --cert) CERT="${2:?--cert needs a path}"; shift 2 ;;
        --key)  KEY="${2:?--key needs a path}"; shift 2 ;;
        --out)  OUT="${2:?--out needs a path}"; shift 2 ;;
        -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$CA" ]   || die "--ca is required (the CA that signed the OTA server cert)"
[ -n "$CERT" ] || die "--cert is required (this device's client certificate)"
[ -n "$KEY" ]  || die "--key is required (this device's private key)"

for f in "$CA" "$CERT" "$KEY"; do
    [ -f "$f" ] || die "not a file: $f"
done

command -v openssl >/dev/null || die "openssl not found on PATH"

# ---------------------------------------------------------------------------
# Validate before staging. Each check below corresponds to a runtime failure
# that is otherwise only visible as a TLS handshake error on the board.
# ---------------------------------------------------------------------------

# 1. The key must belong to the cert. Compare public keys rather than moduli
#    so the check holds for EC keys as well as RSA.
cert_pub="$(openssl x509 -in "$CERT" -noout -pubkey 2>/dev/null)" \
    || die "cannot parse certificate: $CERT"
key_pub="$(openssl pkey -in "$KEY" -pubout 2>/dev/null)" \
    || die "cannot parse private key (is it encrypted?): $KEY"
[ "$cert_pub" = "$key_pub" ] \
    || die "private key does not match certificate — wrong device identity"

# 2. The cert must chain to the CA the server presents.
openssl verify -CAfile "$CA" "$CERT" >/dev/null 2>&1 \
    || die "certificate does not verify against CA $CA — mTLS would be rejected"

# 3. Expiry. Fail on expired, warn inside 30 days.
openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null 2>&1 \
    || die "certificate has expired: $(openssl x509 -in "$CERT" -noout -enddate)"
openssl x509 -in "$CERT" -noout -checkend 2592000 >/dev/null 2>&1 \
    || warn "certificate expires within 30 days: $(openssl x509 -in "$CERT" -noout -enddate)"

# 4. Advisory: a cert carrying an extendedKeyUsage that omits clientAuth is
#    rejected by strict verifiers. A cert with no EKU at all is unrestricted
#    and accepted, which is what a plain `openssl x509 -req` produces.
if openssl x509 -in "$CERT" -noout -ext extendedKeyUsage 2>/dev/null | grep -q .; then
    openssl x509 -in "$CERT" -noout -ext extendedKeyUsage 2>/dev/null \
        | grep -qi 'TLS Web Client Authentication' \
        || warn "certificate has an extendedKeyUsage without clientAuth — a strict server will reject it"
fi

CN="$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null \
        | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p' \
        | tr -d '[:space:]')"
[ -n "$CN" ] || CN="device"

# ---------------------------------------------------------------------------
# Destination. Never inside the repo: the staged key is unencrypted material.
# ---------------------------------------------------------------------------
[ -n "$OUT" ] || OUT="${HOME}/.edge-ota/${CN}"
OUT_ABS="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"

case "$OUT_ABS/" in
    "$REPO_ROOT"/*)
        die "refusing to stage private key inside the repo: $OUT_ABS
    Choose a path outside $REPO_ROOT (default: ~/.edge-ota/<CN>)." ;;
esac

install -d -m 0700 "$OUT_ABS"
install -m 0644 "$CA"   "$OUT_ABS/ca.crt"
install -m 0644 "$CERT" "$OUT_ABS/device.crt"
install -m 0600 "$KEY"  "$OUT_ABS/device.key"

log "Staged device identity for CN=${CN}"
printf '    %s\n' "$OUT_ABS/ca.crt" "$OUT_ABS/device.crt" "$OUT_ABS/device.key"
echo
log "Wire it into the build by adding to kas/local.yml:"
printf '\n    EDGE_OTA_CERT_DIR = "%s"\n\n' "$OUT_ABS"
log "Then rebuild the image; the certs land in /etc/ota on the target."
