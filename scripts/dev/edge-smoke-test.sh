#!/usr/bin/env bash
# On-device smoke test for the edge-ai distro.
#
# Validates the bind-mount persistence architecture (edge-persistence recipe):
#   - /var/log, /var/lib/{containers,systemd,NetworkManager} and /home are bind
#     mounted from /data subdirs (not overlays)
#   - /etc/machine-id and the sshd host keys are captured-or-restored from /data
#     by oneshot services
#   - the RAUC bundle install, journald persistence, container runtime, kernel
#     hardening, and pstore stack continue to work
#
# Designed to be rsync'd onto the target and run as devel (or root):
#   rsync -av scripts/dev/edge-smoke-test.sh devel@<edge>:/tmp/
#   ssh devel@<edge> 'bash /tmp/edge-smoke-test.sh'
#
# Sudo is requested only where strictly required (RAUC status, key inspection).
# The script does not modify RAUC state or touch anything destructive.

set -u
set -o pipefail

# ---------------- output helpers ----------------

if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''; C_RESET=''
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

section() { printf "\n${C_BLUE}== %s ==${C_RESET}\n" "$*"; }
pass()    { printf "  ${C_GREEN}PASS${C_RESET}  %s\n" "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
fail()    { printf "  ${C_RED}FAIL${C_RESET}  %s\n" "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
warn()    { printf "  ${C_YELLOW}WARN${C_RESET}  %s\n" "$*"; WARN_COUNT=$((WARN_COUNT+1)); }
info()    { printf "  ${C_DIM}%s${C_RESET}\n" "$*"; }

# Check a path is bind-mounted from an expected subpath on /data. For bind
# mounts, findmnt SOURCE is "<device>[<fsroot>]" and FSROOT is the subpath
# alone. We compare the FSROOT (e.g. "/log") against the suffix of the
# expected /data path (e.g. /data/log -> "/log") so the check works
# regardless of which device backs /data.
check_bind() {
    local where="$1" expect_source="$2"
    if ! findmnt --target "${where}" -no FSROOT >/dev/null 2>&1; then
        fail "${where}: nothing mounted"
        return
    fi
    local fsroot expect_subpath src
    fsroot=$(findmnt --target "${where}" -no FSROOT | head -1)
    src=$(findmnt --target "${where}" -no SOURCE | head -1)
    expect_subpath="${expect_source#/data}"
    if [ "${fsroot}" = "${expect_subpath}" ]; then
        pass "${where} <- ${src} (fsroot=${fsroot})"
    else
        fail "${where}: fsroot='${fsroot}' source='${src}' (wanted ${expect_source} / fsroot ${expect_subpath})"
    fi
}

# ---------------- 1. system health ----------------

section "System health"

failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
if [ "${failed}" -eq 0 ]; then
    pass "no failed units"
else
    fail "${failed} failed unit(s)"
    systemctl --failed --no-legend | sed 's/^/        /'
fi

uptime_s=$(awk '{print int($1)}' /proc/uptime)
info "uptime: ${uptime_s}s, kernel: $(uname -r)"

# ---------------- 2. /data partition + fstab ----------------

section "/data partition + fstab"

if findmnt /data >/dev/null 2>&1; then
    pass "/data is mounted ($(findmnt -no SOURCE /data))"
    info "/data usage: $(df -h /data | awk 'NR==2{print $3" used / "$2" total ("$5" full)"}')"
else
    fail "/data is NOT mounted — every persistence bind will fail"
fi

if findmnt /boot >/dev/null 2>&1; then
    pass "/boot is mounted ($(findmnt -no SOURCE /boot))"
else
    warn "/boot is not mounted (bundle-hook may have unmounted post-install)"
fi

# ---------------- 3. persistence binds ----------------

section "Persistence binds (edge-persistence)"

check_bind /var/log                  /data/log
check_bind /var/lib/containers       /data/containers
check_bind /var/lib/systemd          /data/systemd
check_bind /var/lib/NetworkManager   /data/nm
check_bind /home                     /data/home

# /var/log must be a real directory in the rootfs (not the volatile-log
# symlink); without that the bind above would land on tmpfs.
if [ -L /var/log ]; then
    fail "/var/log is still a symlink (FILESYSTEM_PERMS_TABLES drop didn't take)"
else
    pass "/var/log is a real directory (volatile-log perms-table dropped)"
fi

# pstore bind is shipped by edge-pstore-persist; lives under /var/lib/systemd
# (which is now ALSO bind-mounted). Confirm both layers compose.
if findmnt /var/lib/systemd/pstore >/dev/null 2>&1; then
    pass "/var/lib/systemd/pstore bound from $(findmnt -no SOURCE /var/lib/systemd/pstore)"
else
    warn "/var/lib/systemd/pstore bind missing (kernel crash capture won't persist)"
fi

# ---------------- 4. journald persistence ----------------

section "journald persistence"

if [ ! -d /run/log/journal ] || [ -z "$(ls -A /run/log/journal 2>/dev/null)" ]; then
    pass "no runtime-only journals on /run (writes go straight to /data)"
else
    fail "journals on /run — bind didn't shadow tmpfs"
    ls -la /run/log/journal/ | sed 's/^/        /'
fi

mid_dir=/var/log/journal
if [ -d "${mid_dir}" ] && [ -n "$(ls -A "${mid_dir}" 2>/dev/null)" ]; then
    journal_file=$(find "${mid_dir}" -maxdepth 2 -name 'system.journal' | head -1)
    if [ -n "${journal_file}" ]; then
        pass "system.journal present at ${journal_file}"
        info "size: $(du -sh "${journal_file}" | awk '{print $1}')"
    else
        fail "machine-id dir present but no system.journal"
    fi
else
    fail "${mid_dir} empty — journald isn't writing persistently"
fi

# Source-of-truth: the actual file should live in /data/log/journal/
if find /data/log/journal -maxdepth 2 -name 'system.journal' 2>/dev/null | grep -q .; then
    pass "/data/log/journal populated (real persistence path)"
else
    fail "/data/log/journal empty — bind not working"
fi

boot_count=$(journalctl --list-boots --no-pager 2>/dev/null | wc -l)
info "boots recorded: ${boot_count}"
if [ "${boot_count}" -ge 2 ]; then
    pass "journal history spans ${boot_count} boots"
else
    warn "only ${boot_count} boot recorded — reboot at least once to prove persistence"
fi

# ---------------- 5. machine-id persistence ----------------

section "machine-id persistence"

if sudo -n test -s /etc/machine-id 2>/dev/null; then
    pass "/etc/machine-id populated ($(sudo cat /etc/machine-id))"
fi

if sudo -n test -s /data/machine-id/id 2>/dev/null; then
    if sudo -n cmp -s /etc/machine-id /data/machine-id/id; then
        pass "/data/machine-id/id matches /etc/machine-id (captured + restorable)"
    else
        fail "/data/machine-id/id present but DOES NOT MATCH /etc/machine-id"
    fi
else
    warn "/data/machine-id/id not yet captured (will be on next boot)"
fi

if systemctl is-active edge-machine-id-persist.service >/dev/null 2>&1; then
    pass "edge-machine-id-persist.service active (exited)"
else
    fail "edge-machine-id-persist.service did not run"
fi

# ---------------- 6. sshd host keys persistence ----------------

section "sshd host keys persistence"

for kt in ed25519 rsa ecdsa; do
    live="/etc/ssh/ssh_host_${kt}_key.pub"
    persist="/data/ssh/ssh_host_${kt}_key.pub"
    if sudo -n test -s "${live}" 2>/dev/null; then
        live_fp=$(sudo ssh-keygen -lf "${live}" 2>/dev/null | awk '{print $2}')
        if sudo -n test -s "${persist}" 2>/dev/null; then
            if sudo -n cmp -s "${live}" "${persist}"; then
                pass "${kt}: live + /data copies match (fp ${live_fp})"
            else
                fail "${kt}: live and /data copies DIFFER (slot-swap will surprise SSH clients)"
            fi
        else
            warn "${kt}: /data/ssh/ copy not yet captured"
        fi
    fi
done

if systemctl is-active edge-ssh-host-keys-persist.service >/dev/null 2>&1; then
    pass "edge-ssh-host-keys-persist.service active (exited)"
else
    fail "edge-ssh-host-keys-persist.service did not run"
fi

# ---------------- 7. container runtime ----------------

section "Container runtime (podman)"

if command -v podman >/dev/null 2>&1; then
    pass "podman: $(podman version --format '{{.Client.Version}}' 2>/dev/null || echo unknown)"
    runtime=$(podman info --format '{{.Host.OCIRuntime.Name}} {{.Host.OCIRuntime.Version}}' 2>/dev/null || true)
    graphroot=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
    info "OCI runtime: ${runtime:-unknown}"
    info "graphRoot:   ${graphroot:-unknown}"

    # podman storage should resolve via the bind to /data/containers
    if [ -d /data/containers/storage ]; then
        pass "podman storage on /data (/data/containers/storage)"
        info "size: $(du -sh /data/containers 2>/dev/null | awk '{print $1}')"
    else
        info "no podman storage yet (no images pulled)"
    fi

    if sudo podman run --rm docker.io/library/alpine:3 echo "container-ok" >/dev/null 2>&1; then
        pass "podman run alpine:3 — OK (pulled + executed)"
    else
        warn "podman run alpine:3 failed (network or registry issue)"
    fi
else
    fail "podman not installed"
fi

# ---------------- 8. RAUC pre-flight ----------------

section "RAUC pre-flight"

if ! command -v rauc >/dev/null 2>&1; then
    fail "rauc not installed"
else
    pass "rauc: $(rauc --version 2>&1 | head -1)"

    keyring=$(awk '
        /^\[keyring\]/ { in_section=1; next }
        /^\[/          { in_section=0 }
        in_section && /^[ \t]*path[ \t]*=/      { sub(/^[^=]*=[ \t]*/, ""); print; exit }
        in_section && /^[ \t]*directory[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); print; exit }
    ' /etc/rauc/system.conf 2>/dev/null || true)
    if [ -n "${keyring}" ] && { [ -f "${keyring}" ] || [ -d "${keyring}" ]; }; then
        pass "keyring present: ${keyring}"
    else
        fail "keyring missing or unreadable: ${keyring:-<unset>}"
    fi

    if status_json=$(sudo -n rauc status --output-format=json 2>/dev/null); then
        booted=$(printf '%s' "${status_json}" | sed -n 's/.*"booted":"\([^"]*\)".*/\1/p' | head -1)
        compat=$(printf '%s' "${status_json}" | sed -n 's/.*"compatible":"\([^"]*\)".*/\1/p' | head -1)
        info "booted slot: ${booted:-unknown}  |  compatible: ${compat:-unknown}"
        pass "rauc status reachable"
    else
        warn "rauc status needs sudo (run \`sudo rauc status\` manually)"
    fi

    # /data/rauc/ is RAUC's data-directory (configured directly in system.conf;
    # NOT going through any bind). Check it exists.
    if sudo -n test -d /data/rauc 2>/dev/null; then
        pass "/data/rauc/ present (RAUC data-directory)"
    else
        warn "/data/rauc/ missing (no slot-state events yet)"
    fi
fi

# ---------------- 9. overlay write markers (cross-slot test prep) ----------------

section "Cross-slot persistence markers"

# /etc/machine-id and host keys already cover identity persistence.
# Add a marker in /home/devel for a "user wrote this on slot A" proof.
home_marker="${HOME}/edge-smoke-marker"
if [ ! -f "${home_marker}" ]; then
    echo "edge-smoke $(date -Is) $(uname -n)" > "${home_marker}" 2>/dev/null \
        && pass "wrote ${home_marker}" \
        || fail "could not write ${home_marker}"
else
    info "${home_marker}: $(cat "${home_marker}")"
fi

# Confirm it landed on /data via the /home bind
home_basename=$(basename "${HOME}")
data_home_marker="/data/home/${home_basename}/edge-smoke-marker"
if [ -f "${data_home_marker}" ] || sudo -n test -f "${data_home_marker}" 2>/dev/null; then
    pass "marker visible at ${data_home_marker} (proves /home bind on /data)"
else
    warn "marker not yet at ${data_home_marker}"
fi

# ---------------- 10. security spot check ----------------

section "Security spot check"

[ -f /sys/fs/cgroup/cgroup.controllers ] \
    && pass "cgroup v2 unified hierarchy" \
    || warn "cgroup v2 not detected"

cmdline=$(cat /proc/cmdline)
for opt in init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on vsyscall=none; do
    case "${cmdline}" in
        *"${opt}"*) pass "kernel cmdline: ${opt}" ;;
        *)          warn "kernel cmdline: ${opt} not set" ;;
    esac
done

# ---------------- summary ----------------

printf "\n${C_BLUE}==================== summary ====================${C_RESET}\n"
printf "  ${C_GREEN}PASS:${C_RESET} %d   ${C_YELLOW}WARN:${C_RESET} %d   ${C_RED}FAIL:${C_RESET} %d\n" \
    "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
