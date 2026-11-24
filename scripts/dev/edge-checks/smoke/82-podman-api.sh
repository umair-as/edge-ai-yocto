# shellcheck shell=bash
# Podman user API: socket-activated, never started eagerly with the user
# manager (it would race the other podman user units for the rootless pause
# process and exit 125). Inactive is its idle state.

edge_check containers.api-socket core "Podman API socket (user managers)" chk_podman_api

# api_check <label> <uid> <prefix...>: one user manager's API socket.
api_check() {
    local label=$1 uid=$2 failed_units ping
    shift 2
    if [ "$("$@" systemctl --user is-active podman.socket 2>/dev/null)" != "active" ]; then
        fail "${label}: podman.socket not listening"
        return
    fi
    if "$@" systemctl --user is-failed --quiet podman.service 2>/dev/null; then
        fail "${label}: podman.service failed before any API request"
    else
        info "${label}: podman.service $("$@" systemctl --user is-active podman.service 2>/dev/null) before the first request"
    fi
    failed_units=$("$@" systemctl --user list-units --failed --plain --no-legend 'podman*' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    if [ -n "${failed_units}" ]; then
        fail "${label}: failed podman user units: ${failed_units}"
    else
        pass "${label}: no failed podman user units"
    fi
    ping=$("$@" curl -s --max-time 15 --unix-socket "/run/user/${uid}/podman/podman.sock" http://d/_ping 2>/dev/null || true)
    if [ "${ping}" = "OK" ]; then
        pass "${label}: API socket activation answers /_ping"
    else
        fail "${label}: API socket activation, /_ping returned '${ping:-nothing}'"
    fi
}

chk_podman_api() {
    local svc_en sock_en boot_journal fd_errs
    if [ ! -e /usr/lib/systemd/user/podman.service ]; then
        info "no podman user units: API socket checks skipped"
        return
    fi
    svc_en=$(systemctl --global is-enabled podman.service 2>/dev/null || true)
    sock_en=$(systemctl --global is-enabled podman.socket 2>/dev/null || true)
    if [ "${svc_en}" = "disabled" ]; then
        pass "podman.service not enabled for user managers (socket-activated)"
    else
        fail "podman.service is '${svc_en:-unknown}' for user managers: it starts eagerly and races"
    fi
    if [ "${sock_en}" = "enabled" ]; then
        pass "podman.socket enabled for user managers"
    else
        fail "podman.socket is '${sock_en:-unknown}' for user managers: no on-demand API"
    fi

    # One user manager started at boot (edge-ctr, linger), one at this login.
    if [ -n "${ECTR_UID}" ] && sudo -n true 2>/dev/null; then
        api_check "edge-ctr" "${ECTR_UID}" sudo -n -u edge-ctr env XDG_RUNTIME_DIR="/run/user/${ECTR_UID}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${ECTR_UID}/bus"
    fi
    if [ "$(id -u)" != 0 ] && [ -S "/run/user/$(id -u)/bus" ]; then
        api_check "$(id -un)" "$(id -u)" env
    fi

    if sudo -n true 2>/dev/null; then
        # Count only a journal that was read: an unreadable one must not pass.
        if boot_journal=$(sudo -n journalctl -b -q --no-pager -o cat 2>/dev/null); then
            fd_errs=$(printf '%s\n' "${boot_journal}" | grep -c "unexpected fd received from systemd" || true)
            if [ "${fd_errs}" -eq 0 ]; then
                pass "no podman 'unexpected fd received from systemd' errors this boot"
            else
                fail "podman API startup race this boot: ${fd_errs} 'unexpected fd' errors (journalctl -b)"
            fi
        else
            fail "boot journal unreadable: podman API startup race not checked"
        fi
    fi
}
