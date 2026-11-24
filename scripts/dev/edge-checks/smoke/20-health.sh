# shellcheck shell=bash
# System health: no failed units, module-signing/lockdown state consistent.

edge_check core.health core "System health" chk_health

chk_health() {
    local failed lockdown_count
    failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
    if [ "${failed}" -eq 0 ]; then
        pass "no failed units"
    else
        fail "${failed} failed unit(s)"
        systemctl --failed --no-legend | sed 's/^/        /'
    fi

    # Lockdown and module signing are coupled: every lockdown level includes
    # LOCKDOWN_MODULE_SIGNATURE. Valid end states: signed modules +
    # lockdown=integrity, or FORCE_NONE with no lockdown= on the cmdline. A
    # "lockdown blocking unsigned modules" message means the build drifted.
    lockdown_count=$(sudo -n dmesg 2>/dev/null | grep -ciE 'lockdown.*unsigned module|lockdown.*restricted')
    if [ "${lockdown_count}" -gt 0 ]; then
        warn "kernel lockdown blocking unsigned modules (${lockdown_count} dmesg hits) — build state drifted from interim FORCE_NONE; see docs/security/uboot-hardening.md (target: sign mmngr/vspm + lockdown=integrity; interim: FORCE_NONE, no lockdown=)"
    fi

    info "uptime: $(awk '{print int($1)}' /proc/uptime)s, kernel: $(uname -r)"
}
