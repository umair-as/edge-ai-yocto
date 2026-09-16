# shellcheck shell=bash
# Source this file to make standalone `kas` invocations behave the same
# as they do under `make`. Idempotent.
#
#   . scripts/env.sh
#   kas shell -c 'bitbake -e | grep DL_DIR'
#
# Why this exists:
#   The Makefile exports KAS_WORK_DIR + KAS_REPO_REF_DIR only to its own
#   sub-processes. Standalone `kas shell` invocations in your interactive
#   shell don't inherit make's environment, so kas falls back to its
#   defaults (KAS_WORK_DIR = CWD = repo root) and re-clones every
#   upstream layer in-tree. Sourcing this file once per shell session
#   lifts the same env into shell scope and avoids the in-tree pollution.
#
# Defaults match the Makefile (Makefile:27-28). Operators with a
# different layout can pre-set either variable before sourcing — the
# `${VAR:-default}` form leaves any existing value alone.

_EDGE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export KAS_WORK_DIR="${KAS_WORK_DIR:-${_EDGE_REPO_ROOT}/.kas}"
export KAS_REPO_REF_DIR="${KAS_REPO_REF_DIR:-/mnt/yocto-nvme/layers-wrynose}"
# Build dir at the traditional repo-root location. Without this, kas
# defaults to ${KAS_WORK_DIR}/build (= .kas/build), which doesn't match
# the universal Yocto convention.
# Mirror the Makefile's resolution exactly, or a standalone `kas shell` writes
# to a different tree than `make` does for the same board. A pre-existing
# single-dir build/ keeps being used for the legacy default board only
# (Yocto's TMPDIR is not relocatable, and another board must not share its
# conf/); otherwise the tree is per-board. Checking BOARD here, not just
# whether build/conf exists, matters once it does: on a host with an
# established rzv2l build/, sourcing this with BOARD already set to
# something else must not still land on the single-dir path.
if [ -d "${_EDGE_REPO_ROOT}/build/conf" ] && [ "${BOARD:-rzv2l}" = "rzv2l" ]; then
    export KAS_BUILD_DIR="${KAS_BUILD_DIR:-${_EDGE_REPO_ROOT}/build}"
else
    export KAS_BUILD_DIR="${KAS_BUILD_DIR:-${_EDGE_REPO_ROOT}/build/${BOARD:-rzv2l}}"
fi

# kas refuses to start if KAS_WORK_DIR doesn't exist (kas/context.py:
# os.path.abspath but no mkdir). Makefile creates it as an order-only
# prereq; replicate for shell-scope invocations.
mkdir -p "${KAS_WORK_DIR}"

echo "edge-ai-yocto kas env loaded:"
echo "  KAS_WORK_DIR=${KAS_WORK_DIR}"
echo "  KAS_BUILD_DIR=${KAS_BUILD_DIR}"
echo "  KAS_REPO_REF_DIR=${KAS_REPO_REF_DIR}"

unset _EDGE_REPO_ROOT
