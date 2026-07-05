#!/usr/bin/env bash
# Install pinned FOSS vulnerability scanners into a repo-local .tooling/bin.
#
# Binaries are gitignored; this script is the committed, re-runnable source
# of truth for which versions the CRA spike used. Re-run to reproduce the
# toolset on a fresh checkout. Idempotent: re-running re-installs the pins.
#
#   scripts/install-scanners.sh            # install everything pinned below
#   scripts/install-scanners.sh grype      # install only the named tool(s)
#
# Versions are pinned for reproducibility. Bump deliberately, not by drift.
set -euo pipefail

# --- pins ------------------------------------------------------------------
GRYPE_VERSION="v0.114.0"
# vexctl / trivy / osv-scanner / syft: added in later spike stages. Pinned
# here when wired so this file stays the single version manifest.
# VEXCTL_VERSION="v0.4.4"

# --- layout ----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/.tooling/bin"
mkdir -p "${BIN_DIR}"

# requested <tool> "$@"  -> true if tool named in args (or no args = all)
requested() { local t="$1"; shift; [ "$#" -eq 0 ] && return 0; for a in "$@"; do [ "$a" = "$t" ] && return 0; done; return 1; }

install_grype() {
    echo ">> grype ${GRYPE_VERSION} -> ${BIN_DIR}"
    # Official installer fetches the prebuilt release binary (no Go build).
    curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
        | sh -s -- -b "${BIN_DIR}" "${GRYPE_VERSION}"
    "${BIN_DIR}/grype" version
}

if requested grype "$@"; then install_grype; fi

echo
echo "Installed under ${BIN_DIR}:"
ls -1 "${BIN_DIR}"
echo
echo "Add to PATH for this shell:  export PATH=\"${BIN_DIR}:\$PATH\""
