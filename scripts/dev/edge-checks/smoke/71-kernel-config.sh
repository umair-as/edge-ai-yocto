# shellcheck shell=bash
# Kernel config expectations shipped in the image: every
# ${EDGE_CHECKS_DIR}/kernel-config-*.list (kernel fragment syntax) must hold
# against the running kernel's config.

edge_check kernel.config-lists core "Kernel config expectations" chk_kernel_config

# kconfig_text: the running kernel's config on stdout; 1 when unreadable.
# EDGE_KCONFIG names a plain-text config instead (host tests).
kconfig_text() {
    if [ -n "${EDGE_KCONFIG:-}" ]; then
        cat "${EDGE_KCONFIG}" 2>/dev/null
    elif [ -r /proc/config.gz ]; then
        gzip -dc /proc/config.gz 2>/dev/null
    else
        cat "/boot/config-$(uname -r)" 2>/dev/null
    fi
}

chk_kernel_config() {
    local lists=() l bad n sym want got
    for l in "${EDGE_CHECKS_DIR}"/kernel-config-*.list; do
        [ -f "${l}" ] && lists+=("${l}")
    done
    if [ ${#lists[@]} -eq 0 ]; then
        warn "no kernel config expectation lists (${EDGE_CHECKS_DIR}/kernel-config-*.list); check skipped"
        return
    fi
    if ! kconfig_text | grep '^CONFIG_' >/dev/null; then
        warn "kernel config not readable (/proc/config.gz, /boot/config-$(uname -r)); ${#lists[@]} list(s) not checked"
        return
    fi
    for l in "${lists[@]}"; do
        bad=$(kconfig_mismatches "${l}" <(kconfig_text))
        n=$(kconfig_count "${l}")
        if [ -z "${bad}" ]; then
            pass "$(basename "${l}"): ${n} kernel config expectations hold"
        else
            while read -r sym want got; do
                [ "${got}" = n ] && got="not set"
                [ "${want}" = n ] && want="not set"
                fail "$(basename "${l}"): ${sym} is ${got}, expected ${want}"
            done <<< "${bad}"
        fi
    done
}
