# shellcheck shell=bash
# Rootless containers as edge-ctr, the principal AI workloads run as
# (ADR-0012): storage, pull, user namespace, DNS/HTTPS, published port,
# cgroup delegation, Quadlet generator. Test containers are removed.

edge_check containers.rootless-edge-ctr core "Rootless containers as edge-ctr" chk_rootless_edge_ctr

# ectr <cmd...>: run as edge-ctr with its user-session environment, from /tmp
# (edge-ctr cannot enter the caller's cwd).
ectr() {
    (cd /tmp && sudo -n -u edge-ctr env XDG_RUNTIME_DIR="/run/user/${ECTR_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${ECTR_UID}/bus" HOME="${ECTR_HOME}" "$@")
}

chk_rootless_edge_ctr() {
    local root out cg
    if [ -z "${ECTR_UID}" ] || ! command -v podman >/dev/null 2>&1; then
        info "edge-ctr or podman absent: rootless edge-ctr checks skipped"
        return
    fi
    if ! sudo -n true 2>/dev/null; then
        info "no passwordless sudo: rootless edge-ctr checks skipped"
        return
    fi

    root=$(ectr podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
    case "${root}" in
        /data/*) pass "edge-ctr storage on /data (${root})" ;;
        *)       fail "edge-ctr storage not on /data (${root:-podman info failed})" ;;
    esac

    # Fresh pull (scratch dir), user-namespace mapping, DNS and HTTPS in one run.
    out=$(ectr podman run --rm --pull=always docker.io/library/alpine:3 sh -c \
        'id -u; nslookup -type=a example.com >/dev/null 2>&1 && echo dns-ok; wget -q -O /dev/null https://example.com && echo https-ok' 2>&1)
    if printf '%s\n' "${out}" | grep -qx 0 \
            && printf '%s\n' "${out}" | grep -qx dns-ok \
            && printf '%s\n' "${out}" | grep -qx https-ok; then
        pass "edge-ctr rootless run: fresh pull, root mapped, DNS + HTTPS"
    else
        case "${out}" in
            *"creating a temporary directory"*)
                fail "edge-ctr rootless pull failed: <graphroot>/tmp missing (edge-ctr.tmpfiles)" ;;
            *"no such host"*|*"lookup "*|*"Temporary failure in name resolution"*)
                warn "edge-ctr rootless run failed on name resolution (first-boot DNS); rerun later" ;;
            *)
                fail "edge-ctr rootless run incomplete: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-160)" ;;
        esac
    fi

    # Published port through pasta, answered on loopback.
    ectr podman rm -f edge-smoke-port >/dev/null 2>&1 || true
    if ectr podman run -d --name edge-smoke-port -p 127.0.0.1:18089:80 docker.io/library/alpine:3 \
            sh -c 'while true; do printf "HTTP/1.0 200 OK\r\n\r\nedge-smoke\n" | nc -l -p 80; done' >/dev/null 2>&1; then
        sleep 2
        if curl -s --max-time 5 http://127.0.0.1:18089/ 2>/dev/null | grep -qx edge-smoke; then
            pass "edge-ctr rootless published port answers"
        else
            fail "edge-ctr rootless published port did not answer on 127.0.0.1:18089"
        fi
    else
        fail "edge-ctr rootless container with a published port failed to start"
    fi
    ectr podman rm -f edge-smoke-port >/dev/null 2>&1 || true

    # cpuset delegation lets workloads pin to a core type (--cpuset-cpus).
    cg=$(ectr podman info --format '{{.Host.CgroupControllers}}' 2>/dev/null || true)
    case "${cg}" in
        *cpuset*) pass "edge-ctr delegated controllers ${cg}" ;;
        *)        fail "edge-ctr delegated controllers ${cg:-unknown}: cpuset missing (user@${ECTR_UID} drop-in)" ;;
    esac

    if ectr /usr/lib/systemd/user-generators/podman-user-generator --dryrun >/dev/null 2>&1; then
        pass "Quadlet user generator runs for edge-ctr"
    else
        fail "Quadlet user generator failed for edge-ctr"
    fi
}
