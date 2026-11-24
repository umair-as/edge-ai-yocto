# shellcheck shell=bash
# Container runtime: podman with netavark + pasta, storage on /data, root and
# rootless (as the invoking user) runs.

edge_check containers.podman core "Container runtime (podman)" chk_podman

# podman_run_verdict <root|rootless> <stderr>: name the cause of a failed run.
# A missing nft binary is an image defect (netavark's nftables driver execs it
# for every root container network); a DNS failure is first-boot timing.
podman_run_verdict() {
    local who=$1 err=$2
    if [ "${who}" = root ]; then
        case "${err}" in
            *'unable to execute "nft"'*|*'nft: No such file'*)
                fail "root podman run failed: netavark cannot exec nft — nftables userspace missing from the image" ;;
            *"no such host"*|*"lookup "*|*"Temporary failure in name resolution"*)
                warn "root podman run failed on name resolution (first-boot DNS); rerun later" ;;
            *)
                fail "root podman run alpine:3 failed: $(printf '%s' "${err}" | tail -1 | cut -c1-160)" ;;
        esac
    else
        case "${err}" in
            *"creating a temporary directory"*)
                fail "rootless podman run failed: <graphroot>/tmp missing (tmpfiles entry for $(id -un))" ;;
            *"no such host"*|*"lookup "*|*"Temporary failure in name resolution"*)
                warn "rootless podman run failed on name resolution (first-boot DNS); rerun later" ;;
            *)
                fail "rootless podman run as $(id -un) failed: $(printf '%s' "${err}" | tail -1 | cut -c1-160)" ;;
        esac
    fi
}

chk_podman() {
    local runtime graphroot netbackend netpkg dnspkg err rc
    if ! command -v podman >/dev/null 2>&1; then
        fail "podman not installed"
        return
    fi
    pass "podman: $(podman version --format '{{.Client.Version}}' 2>/dev/null || echo unknown)"
    runtime=$(podman info --format '{{.Host.OCIRuntime.Name}} {{.Host.OCIRuntime.Version}}' 2>/dev/null || true)
    graphroot=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
    netbackend=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)
    netpkg=$(podman info --format '{{.Host.NetworkBackendInfo.Package}}' 2>/dev/null || true)
    dnspkg=$(podman info --format '{{.Host.NetworkBackendInfo.DNS.Package}}' 2>/dev/null || true)
    info "OCI runtime:    ${runtime:-unknown}"
    info "graphRoot:      ${graphroot:-unknown}"
    info "network/dns:    ${netpkg:-unknown} + ${dnspkg:-unknown}"

    case "${netbackend}" in
        netavark) pass "podman network backend = netavark" ;;
        cni)      fail "podman network backend = cni (legacy; should be netavark)" ;;
        *)        warn "podman network backend = ${netbackend:-unknown}" ;;
    esac

    # pasta is the podman 5.x rootless network mode; without it every
    # rootless `podman run` errors at "could not find pasta".
    if command -v pasta >/dev/null 2>&1; then
        pass "pasta available at $(command -v pasta)"
    else
        fail "pasta not installed — rootless networking falls back to slirp4netns"
    fi

    if [ -d /data/containers/storage ]; then
        pass "podman storage on /data (/data/containers/storage)"
        info "size: $(du -sh /data/containers 2>/dev/null | awk '{print $1}')"
    else
        info "no podman storage yet (no images pulled)"
    fi

    err=$(sudo -n podman run --rm docker.io/library/alpine:3 echo "container-ok" 2>&1 >/dev/null); rc=$?
    if [ "${rc}" -eq 0 ]; then
        pass "podman run alpine:3 — OK (pulled + executed)"
    else
        podman_run_verdict root "${err}"
    fi

    # Rootless as the invoking user covers pasta, subuid mapping and the
    # image-copy scratch dir (<graphroot>/tmp, from tmpfiles) that a root run
    # never touches. --pull=always: a cached image skips the scratch dir.
    if [ "$(id -u)" -ne 0 ]; then
        err=$(podman run --rm --pull=always docker.io/library/alpine:3 echo "container-ok" 2>&1 >/dev/null); rc=$?
        if [ "${rc}" -eq 0 ]; then
            pass "rootless podman run alpine:3 as $(id -un) — OK"
        else
            podman_run_verdict rootless "${err}"
        fi
    else
        info "running as root: rootless podman not checked"
    fi
}
