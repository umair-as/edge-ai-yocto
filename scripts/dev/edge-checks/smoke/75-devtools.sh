# shellcheck shell=bash
# Bring-up tooling shipped in the dev image (packagegroup-edge-hwtools).

edge_check devtools.bringup cap:dev-tools "Bring-up tooling (dev image)" chk_devtools

edge_cap_dev_tools() {
    case "${EDGE_IMAGE}" in
        *-dev) return 0 ;;
        *) echo "image ${EDGE_IMAGE:-unrecorded} is not a dev image"; return 1 ;;
    esac
}

chk_devtools() {
    local tool
    for tool in dtc fdtdump fdtget tune2fs e2label; do
        if command -v "${tool}" >/dev/null 2>&1; then
            pass "${tool} available at $(command -v "${tool}")"
        else
            warn "${tool} not on PATH"
        fi
    done
}
