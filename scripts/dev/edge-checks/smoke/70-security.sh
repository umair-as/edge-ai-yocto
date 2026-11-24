# shellcheck shell=bash
# Security baseline: cgroup v2, hardening cmdline, SELinux active and labelled.

edge_check security.baseline core "Security spot check" chk_security

chk_security() {
    local opt enforce sh_ctx sel_mode sel_type
    [ -f /sys/fs/cgroup/cgroup.controllers ] \
        && pass "cgroup v2 unified hierarchy" \
        || warn "cgroup v2 not detected"

    for opt in init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on vsyscall=none; do
        case "${EDGE_CMDLINE}" in
            *"${opt}"*) pass "kernel cmdline: ${opt}" ;;
            *)          warn "kernel cmdline: ${opt} not set" ;;
        esac
    done

    # security=selinux on the cmdline; the mode comes from /etc/selinux/config.
    case "${EDGE_CMDLINE}" in
        *security=selinux*) pass "kernel cmdline: security=selinux" ;;
        *selinux=0*)        warn "kernel cmdline: selinux=0 (recovery override; expected security=selinux)" ;;
        *)                  warn "kernel cmdline: no SELinux flag (LSM may not be active)" ;;
    esac
    case "${EDGE_CMDLINE}" in
        *enforcing=0*) warn "kernel cmdline: enforcing=0 still present (should come from /etc/selinux/config now)" ;;
    esac

    if command -v getenforce >/dev/null 2>&1; then
        enforce=$(getenforce 2>/dev/null || true)
        case "${enforce}" in
            Permissive) pass "SELinux state: Permissive (refpolicy DEFAULT_ENFORCING=permissive)" ;;
            Enforcing)  info "SELinux state: Enforcing (post-validation flip; not the v0 default)" ;;
            Disabled)   warn "SELinux state: Disabled (kernel built it out OR selinux=0 escape)" ;;
            *)          warn "SELinux state: unknown ('${enforce}')" ;;
        esac
        # stat -c %C reads one file's context without the ls -lZ column trap.
        if [ "${enforce}" != "Disabled" ]; then
            sh_ctx=$(stat -c '%C' /bin/sh 2>/dev/null || true)
            case "${sh_ctx}" in
                *unlabeled_t*) fail "/bin/sh has SELinux context ${sh_ctx} — rootfs not labeled" ;;
                *bin_t*|*shell_exec_t*) pass "/bin/sh SELinux context: ${sh_ctx}" ;;
                "?"|"") info "/bin/sh label not displayable (selinux=0 boot)" ;;
                *) info "/bin/sh SELinux context: ${sh_ctx}" ;;
            esac
        fi
    fi

    if [ -f /etc/selinux/config ]; then
        sel_mode=$(awk -F= '/^SELINUX=/ {print $2; exit}' /etc/selinux/config)
        sel_type=$(awk -F= '/^SELINUXTYPE=/ {print $2; exit}' /etc/selinux/config)
        info "/etc/selinux/config: SELINUX=${sel_mode}, SELINUXTYPE=${sel_type}"
    fi
}
