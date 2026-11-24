#!/usr/bin/env bash
# Assembles each on-device check suite into one self-contained script, so a
# board runs it as a file or as `bash -s` on stdin:
#   <suite>/header.sh + lib.sh + <suite>/[0-9]*.sh (in name order) + entry point
# Suites: smoke -> scripts/dev/edge-smoke-test.sh, verity -> scripts/dev/edge-verity-check.sh.
#
#   scripts/dev/edge-checks/build.sh            regenerate both scripts
#   scripts/dev/edge-checks/build.sh --check    exit 1 if a generated script is stale
set -euo pipefail

D=$(cd "$(dirname "$0")" && pwd)
OUT=$(dirname "$D")
SUITES="smoke:edge-smoke-test.sh verity:edge-verity-check.sh"

# body <file>: the file without its leading shellcheck shell= directive.
body() { sed '1{/^# shellcheck shell=bash/d}' "$1"; }

assemble() {
    local suite=$1 m
    cat "${D}/${suite}/header.sh"
    printf '\n# ---------------- edge-checks/lib.sh ----------------\n\n'
    body "${D}/lib.sh"
    for m in "${D}/${suite}"/[0-9]*.sh; do
        printf '\n# ---------------- edge-checks/%s/%s ----------------\n\n' "${suite}" "$(basename "${m}")"
        body "${m}"
    done
    printf '\n# ---------------- entry point ----------------\n\n'
    printf 'if [ "${EDGE_CHECKS_SOURCE_ONLY:-0}" != 1 ]; then\n    edge_main "$@"\n    exit $?\nfi\n'
}

rc=0
for s in ${SUITES}; do
    suite=${s%%:*} target=${OUT}/${s#*:}
    if [ "${1:-}" = --check ]; then
        if ! assemble "${suite}" | cmp -s - "${target}"; then
            echo "${target#"$(dirname "$(dirname "${OUT}")")"/} is stale: run scripts/dev/edge-checks/build.sh" >&2
            rc=1
        fi
    else
        assemble "${suite}" > "${target}.tmp"
        chmod 0755 "${target}.tmp"
        mv "${target}.tmp" "${target}"
    fi
done
exit "${rc}"
