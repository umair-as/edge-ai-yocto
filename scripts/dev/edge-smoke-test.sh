#!/usr/bin/env bash
# On-device smoke test for the edge-ai distro.
#
# Board-neutral: the machine, its uplink interface and its accelerator are
# read from the image (/etc/buildinfo, the shipped networkd units, the
# installed accelerator stack), not assumed. Runs on RZ/V2L and Raspberry Pi 5.
#
# Validates the bind-mount persistence architecture (edge-persistence recipe):
#   - /var/log, /var/lib/{containers,systemd} and /home are bind
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
# alone. Compare the FSROOT (e.g. "/log") against the suffix of the
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

# ---------------- 0. board identity ----------------

section "Board identity"

EDGE_MACHINE=$(awk -F= '/^MACHINE=/{print $2; exit}' /etc/buildinfo 2>/dev/null)
EDGE_BUILD_ID=$(awk -F= '/^EDGE_BUILD_ID=/{print $2; exit}' /etc/buildinfo 2>/dev/null)
if [ -n "${EDGE_MACHINE}" ]; then
    pass "MACHINE=${EDGE_MACHINE} build ${EDGE_BUILD_ID:-?} ($(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'model unknown'))"
else
    fail "/etc/buildinfo has no MACHINE= — cannot derive board facts; checks below assume nothing"
fi

# Uplink = the shipped networkd unit that is not Unmanaged; unmanaged = the
# rest. edge-network-units templates both from the board include, so the
# image itself says which interface carries DHCP.
EDGE_UPLINK=""; EDGE_UNMANAGED=""
for u in /etc/systemd/network/10-*.network; do
    [ -f "${u}" ] || continue
    n=$(basename "${u}" .network); n=${n#10-}
    if grep -qE '^\s*Unmanaged\s*=\s*yes' "${u}"; then EDGE_UNMANAGED="${EDGE_UNMANAGED} ${n}"; else EDGE_UPLINK="${n}"; fi
done
info "uplink: ${EDGE_UPLINK:-?}  unmanaged:${EDGE_UNMANAGED:- none}"

# ---------------- 1. system health ----------------

section "System health"

failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
if [ "${failed}" -eq 0 ]; then
    pass "no failed units"
else
    fail "${failed} failed unit(s)"
    systemctl --failed --no-legend | sed 's/^/        /'
fi

# Lockdown LSM and module signing are intrinsically coupled — both integrity
# and confidentiality bands include LOCKDOWN_MODULE_SIGNATURE, so any
# lockdown level blocks unsigned modules. The two valid end-states are:
#   TARGET — modules signed + lockdown=integrity activated via cmdline
#   INTERIM — FORCE_NONE in kernel cfg, no lockdown= on cmdline; LSM dormant
# A "lockdown blocking unsigned modules" message at runtime means the build
# state drifted (e.g. FORCE_CONFIDENTIALITY=y crept back in or cmdline got
# a stray lockdown=integrity without signing the out-of-tree modules).
lockdown_count=$(sudo -n dmesg 2>/dev/null | grep -ciE 'lockdown.*unsigned module|lockdown.*restricted')
if [ "${lockdown_count}" -gt 0 ]; then
    warn "kernel lockdown blocking unsigned modules (${lockdown_count} dmesg hits) — build state drifted from interim FORCE_NONE; see docs/security/uboot-hardening.md (target: sign mmngr/vspm + lockdown=integrity; interim: FORCE_NONE, no lockdown=)"
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

# WIC fstab dup-trap: WIC's update_fstab() used to append /dev/mmcblk0pN
# entries on top of the base-files fstab, causing systemd-fstab-generator
# "already exists. Duplicate entry?" errors. Fix is the imager-level
# WIC_CREATE_EXTRA_ARGS:append = " --no-fstab-update" in edge-image.bbclass.
fstab_dups=$(awk '!/^\s*(#|$)/ {print $2}' /etc/fstab | sort | uniq -d)
if [ -z "${fstab_dups}" ]; then
    pass "/etc/fstab has no duplicate mountpoints"
else
    fail "/etc/fstab has duplicate mountpoint(s): ${fstab_dups}"
fi
if ! journalctl -b 0 -u systemd-fstab-generator --no-pager 2>/dev/null \
       | grep -qi 'duplicate entry'; then
    pass "systemd-fstab-generator has no 'Duplicate entry' errors this boot"
else
    fail "systemd-fstab-generator logged 'Duplicate entry' — WIC dup-fstab trap struck"
fi

# /data reserve-blocks: grow script now runs `tune2fs -m 0` after resize2fs
# (reclaims ~5% of partition). Confirm the superblock has 0% reserve.
if command -v dumpe2fs >/dev/null 2>&1; then
    data_src=$(findmnt -no SOURCE /data 2>/dev/null || true)
    if [ -b "${data_src}" ]; then
        reserve=$(sudo -n dumpe2fs -h "${data_src}" 2>/dev/null \
            | awk -F: '/Reserved block count/ {gsub(/ /, "", $2); print $2; exit}')
        if [ "${reserve}" = "0" ]; then
            pass "/data reserved-blocks = 0 (tune2fs -m 0 ran)"
        elif [ -n "${reserve}" ]; then
            warn "/data reserved-blocks = ${reserve} (tune2fs -m 0 not yet applied)"
        else
            warn "could not read /data reserved-blocks (sudo dumpe2fs returned nothing)"
        fi
    fi
fi

# ---------------- 3. persistence binds ----------------

section "Persistence binds (edge-persistence)"

check_bind /var/log                  /data/log
check_bind /var/lib/containers       /data/containers
check_bind /var/lib/systemd          /data/systemd
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
    live="/run/edge-sshd-keys/ssh_host_${kt}_key.pub"
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

    # pasta is the podman 5.x default rootless network mode. Without it, every
    # rootless `podman run` errors at "could not find pasta".
    if command -v pasta >/dev/null 2>&1; then
        pass "pasta available at $(command -v pasta)"
    else
        fail "pasta not installed — rootless networking falls back to slirp4netns"
    fi

    # podman storage should resolve via the bind to /data/containers
    if [ -d /data/containers/storage ]; then
        pass "podman storage on /data (/data/containers/storage)"
        info "size: $(du -sh /data/containers 2>/dev/null | awk '{print $1}')"
    else
        info "no podman storage yet (no images pulled)"
    fi

    # Run-with-pull. Captures stderr so a real failure (vs. transient first-boot
    # DNS not-yet-settled) is visible. Smoke test runs at uptime ~2-4 min;
    # networkd-without-resolved may not have written a resolvable DNS server yet
    # (the Network section reports whether /etc/resolv.conf got populated).
    podman_run_err=$(sudo -n podman run --rm docker.io/library/alpine:3 echo "container-ok" 2>&1 >/dev/null)
    if [ $? -eq 0 ]; then
        pass "podman run alpine:3 — OK (pulled + executed)"
    else
        # Name the cause: a missing nft binary is an image defect (netavark's
        # nftables driver execs it for every root container network), a DNS
        # failure is first-boot timing. Only the second is transient.
        case "${podman_run_err}" in
            *'unable to execute "nft"'*|*'nft: No such file'*)
                fail "root podman run failed: netavark cannot exec nft — nftables userspace missing from the image" ;;
            *"no such host"*|*"lookup "*|*"Temporary failure in name resolution"*)
                warn "root podman run failed on name resolution (first-boot DNS); rerun later" ;;
            *)
                fail "root podman run alpine:3 failed: $(printf '%s' "${podman_run_err}" | tail -1 | cut -c1-160)" ;;
        esac
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

# SELinux state. EXTRA_KERNEL_ARGS in U-Boot env should append `security=selinux`
# (no `enforcing=0` — refpolicy /etc/selinux/config now drives the mode).
case "${cmdline}" in
    *security=selinux*) pass "kernel cmdline: security=selinux" ;;
    *selinux=0*)        warn "kernel cmdline: selinux=0 (recovery override; expected security=selinux)" ;;
    *)                  warn "kernel cmdline: no SELinux flag (LSM may not be active)" ;;
esac
case "${cmdline}" in
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
    # Confirm the file system is labeled — /bin/sh should NOT be unlabeled_t.
    # stat -c %C is the canonical way to read the SELinux context for one file
    # (avoids the ls -lZ column-order trap on different coreutils versions).
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

# Refpolicy config — Permissive is the v0 default; ADR-0005 follow-up flips
# to Enforcing once policy coverage is audit-clean.
if [ -f /etc/selinux/config ]; then
    sel_mode=$(awk -F= '/^SELINUX=/ {print $2; exit}' /etc/selinux/config)
    sel_type=$(awk -F= '/^SELINUXTYPE=/ {print $2; exit}' /etc/selinux/config)
    info "/etc/selinux/config: SELINUX=${sel_mode}, SELINUXTYPE=${sel_type}"
fi

# ---------------- 11. bring-up tooling ----------------

section "Bring-up tooling (dev image)"

# Tools added across the SELinux / podman / image-class refactor this cycle:
#   dtc, fdtdump, fdtget        — device tree inspection (hwtools)
#   tune2fs, e2label             — ext4 metadata (hwtools + grow-data RDEPENDS)
#   pasta                        — already checked in section 7
for tool in dtc fdtdump fdtget tune2fs e2label; do
    if command -v "${tool}" >/dev/null 2>&1; then
        pass "${tool} available at $(command -v "${tool}")"
    else
        warn "${tool} not on PATH"
    fi
done

# /data growth is one unified oneshot for both layouts: edge-grow-data.service
# dispatches systemd-repart (GPT/eMMC) or parted (MBR/eSD) plus a shared
# resize2fs + tune2fs tail. Gated by /boot/.edge-data-grown, so it runs once on
# the first boot of a fresh flash — look across all boots for that run.
if journalctl -u edge-grow-data.service --no-pager 2>/dev/null | grep -qiE '✓|▶|⏭|growth complete'; then
    pass "edge-grow-data.service ran (/data growth logged)"
elif [ "$(systemctl is-active edge-grow-data.service 2>/dev/null)" = "active" ]; then
    pass "edge-grow-data.service active (exited) — /data growth"
else
    warn "edge-grow-data.service log absent or unparsed"
fi

# ---------------- 12. lingering user managers (boot auto-start) ----------------

section "Lingering user managers (boot auto-start)"

# Linger MARKERS existing is not enough — logind must actually start the user
# managers at boot. A logind linger-enumeration race (ESRCH on the first
# boot of a freshly-OTA'd slot, self-heals on reboot) can leave markers
# present but managers dead, so rootless boot services (Podman Quadlets) never
# run. Under permissive this is NOT the default_t label (denials don't enforce);
# under enforcing default_t on /var/lib/systemd would additionally block logind_t
# search (see roadmap Q4). logind's enumeration log is the definitive boot-time
# signal — it survives later manual recovery of the session.
if sudo -n journalctl -b -u systemd-logind --no-pager 2>/dev/null \
       | grep -qiE 'User enumeration failed|Couldn.t add lingering user'; then
    fail "systemd-logind failed to enumerate lingering users this boot — userdb refused the records (workers started before /etc/machine-id was restored; edge-persistence orders systemd-userdbd after it). Rootless Quadlets won't auto-start until userdbd's workers recycle (~5 min) or \`systemctl restart systemd-userdbd\`"
else
    pass "systemd-logind enumerated lingering users cleanly this boot"
fi

# Per-user end state. A user with an active session (e.g. devel over SSH) shows
# active regardless of linger, so the non-login principals (edge-ctr) are the
# meaningful proof that linger auto-start worked.
for u in edge-ctr devel; do
    uid=$(id -u "${u}" 2>/dev/null || true)
    [ -z "${uid}" ] && { info "${u}: no such user"; continue; }
    if ! sudo -n test -e "/var/lib/systemd/linger/${u}" 2>/dev/null; then
        info "${u}: linger not enabled"
        continue
    fi
    if [ -d "/run/user/${uid}" ] && systemctl is-active "user@${uid}.service" >/dev/null 2>&1; then
        pass "${u} (uid ${uid}): user manager active + /run/user/${uid} present"
    else
        fail "${u} (uid ${uid}): linger marker present but user@${uid} inactive / no /run/user/${uid}"
    fi
done

# ---------------- 13. accelerator ----------------

# Every board carries one; which one is read from the image, not assumed.
# DRP-AI (RZ/V2L): kernel-module-drpai + render-group nodes. DX-M1 (RPi5):
# edge-dxm1-runtime's udev rule + dxrtd + the PCIe endpoint.
accel="none"
drpai_ko=$(find "/lib/modules/$(uname -r)" -name 'drpai.ko*' 2>/dev/null | head -1)
[ -n "${drpai_ko}" ] && accel="drpai-v2l"
[ -f /etc/udev/rules.d/71-edge-dxm1.rules ] && accel="dxm1"

section "Accelerator (${accel})"

if [ "${accel}" = "dxm1" ]; then
    # PCIe endpoint: DEEPX vendor id 1ff4. The bridge is built in and the
    # driver is autoloaded from the modalias, so an absent endpoint means the
    # card, the slot or the link — not the image.
    if command -v lspci >/dev/null 2>&1; then
        dx_bdf=$(lspci -d 1ff4: -n 2>/dev/null | awk '{print $1; exit}')
        if [ -n "${dx_bdf}" ]; then
            pass "DX-M1 endpoint on PCIe at ${dx_bdf}"
            ctl=$(sudo -n lspci -vvs "${dx_bdf}" 2>/dev/null | grep -m1 -E '^\s*Control:')
            case "${ctl}" in
                *Mem+*BusMaster+*) pass "endpoint Control: Mem+ BusMaster+" ;;
                "") warn "lspci -vv needs sudo; endpoint control state not read" ;;
                *) fail "endpoint not enabled: ${ctl}" ;;
            esac
            aspm=$(sudo -n lspci -vvs "${dx_bdf}" 2>/dev/null | grep -m1 -oE 'ASPM (Disabled|L0s|L1|L0s L1)')
            [ -n "${aspm}" ] && info "link ${aspm}"
        else
            fail "no DEEPX (1ff4) PCIe endpoint enumerated — card not detected"
        fi
    else
        warn "lspci absent — PCIe endpoint not inspected"
    fi
    case "$(cat /proc/cmdline)" in
        *pcie_aspm=off*) pass "kernel cmdline: pcie_aspm=off (BCM2712 + DX-M1 SError guard)" ;;
        *) fail "kernel cmdline lacks pcie_aspm=off — link-state resets panic this board" ;;
    esac
    if sudo -n dmesg 2>/dev/null | grep -qiE 'AER:.*(Uncorrect|Correct)ed error'; then
        warn "PCIe AER errors logged this boot (dmesg | grep AER)"
    else
        pass "no PCIe AER errors this boot"
    fi
    for m in dx_dma dxrt_driver; do
        lsmod | grep -q "^${m} " && pass "module ${m} loaded" || fail "module ${m} not loaded (udev modalias autoload after PCIe enumeration)"
    done
    if [ -e /dev/dxrt0 ]; then
        l=$(ls -l /dev/dxrt0)
        if printf '%s' "${l}" | grep -qE '^crw-rw----.* root dxrt '; then
            pass "/dev/dxrt0 root:dxrt 0660"
        else
            fail "/dev/dxrt0 not root:dxrt 0660: ${l}"
        fi
    else
        fail "/dev/dxrt0 missing — dxrt_driver found no device"
    fi
    if systemctl is-active dxrtd.service >/dev/null 2>&1; then
        dx_user=$(ps -o user= -C dxrtd 2>/dev/null | head -1)
        [ "${dx_user}" = "dxrt" ] && pass "dxrtd active as dxrt" || fail "dxrtd active but running as '${dx_user:-?}' (expected dxrt)"
    else
        fail "dxrtd.service not active ($(systemctl is-active dxrtd.service 2>/dev/null)) — ConditionPathExistsGlob=/dev/dxrt* unmet, or the daemon failed"
    fi
    if command -v dxrt-cli >/dev/null 2>&1; then
        dx_status=$(sudo -n timeout 20 dxrt-cli -s 2>&1 | head -20)
        if printf '%s' "${dx_status}" | grep -qiE 'device|firmware|fw'; then
            pass "dxrt-cli -s reports a device"
            printf '%s\n' "${dx_status}" | grep -iE 'device|firmware|fw|version' | head -4 | sed 's/^/        /'
        else
            warn "dxrt-cli -s gave no device report (daemon/firmware handshake): $(printf '%s' "${dx_status}" | head -1)"
        fi
    fi
    id -nG edge-ctr 2>/dev/null | tr ' ' '\n' | grep -qx dxrt \
        && pass "edge-ctr is in dxrt (rootless passthrough via keep-groups)" \
        || fail "edge-ctr is not in the dxrt group"
    if sudo -n test -f /data/dxm1/bin/run_model 2>/dev/null; then
        pass "/data/dxm1 inference payload present"
        if sudo -n journalctl _UID=608 -b --no-pager 2>/dev/null | grep -qiE 'dxm1|run_model'; then
            pass "DX-M1 inference Quadlet ran this boot (user-608 journal)"
        else
            fail "payload present but the dxm1-inference Quadlet left no trace this boot"
        fi
    else
        info "no /data/dxm1 payload — Quadlet skips (expected on a fresh flash; stage runtime libs + model + run_model there to enable)"
    fi
    if [ -f /etc/systemd/user/podman-user-wait-network-online.service.d/10-edge-noop.conf ]; then
        pass "podman-user-wait no-op drop-in present (no 90s inference delay)"
    else
        warn "podman-user-wait no-op drop-in missing — first inference likely delayed ~90s at boot"
    fi
elif [ "${accel}" = "none" ]; then
    fail "no accelerator stack installed — the accelerator is baseline on every board, so this is a build or composition fault, not an image variant"
else
    # Accelerator + zero-copy buffer nodes. render-group 0660 ownership (from
    # edge-drpai-udev) is what lets the rootless container open them via
    # keep-groups; root:root 0600 would break the passthrough.
    for n in drpai0 udmabuf0; do
        if [ -e "/dev/${n}" ]; then
            l=$(ls -l "/dev/${n}")
            if printf '%s' "${l}" | grep -q 'root render'; then
                pass "/dev/${n}: $(printf '%s' "${l}" | awk '{print $1, $3":"$4}')"
            else
                fail "/dev/${n} not root:render (rootless passthrough breaks): ${l}"
            fi
        else
            fail "/dev/${n} missing — module installed but driver did not bind"
        fi
    done

    for m in drpai u_dma_buf; do
        lsmod | grep -q "^${m} " && pass "module ${m} loaded" || fail "module ${m} not loaded"
    done

    # drp_reserved is a static 512 MB carveout; usable RAM should be well under
    # 1.5 GB on this 2 GB board if it applied.
    memtotal_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    if [ "${memtotal_kb}" -lt 1500000 ]; then
        pass "drp_reserved carveout in effect (MemTotal ${memtotal_kb} kB)"
    else
        warn "MemTotal ${memtotal_kb} kB — drp_reserved 512 MB carveout may not have applied"
    fi

    grep -q 'drpa mac_nmlint' /proc/interrupts \
        && pass "DRP-AI AI-MAC completion interrupt registered" \
        || warn "DRP-AI AI-MAC interrupt absent in /proc/interrupts"

    if sudo -n test -f /data/drpai/bin/drpai-tutorial-app 2>/dev/null; then
        payload_present=1
        pass "/data/drpai inference payload present"
    else
        payload_present=0
        warn "/data/drpai payload missing — fresh /data; place it to enable inference (Quadlet ConditionPathExists skips without it)"
    fi

    # The 90s podman-user-wait-network-online timeout (podman #22197) is
    # neutralized by a no-op ExecStart drop-in; without it inference is delayed
    # ~90s every boot (the wait unit polls a user-scope network-online.target
    # that never goes active, then times out).
    if [ -f /etc/systemd/user/podman-user-wait-network-online.service.d/10-edge-noop.conf ]; then
        pass "podman-user-wait no-op drop-in present (no 90s inference delay)"
    else
        warn "podman-user-wait no-op drop-in missing — first inference likely delayed ~90s at boot"
    fi

    # Inference auto-start: only meaningful if the payload exists — the Quadlet
    # ConditionPathExists skips cleanly without it (expected on a fresh flash,
    # where /data carries no payload yet). A manual run also satisfies this.
    if sudo -n journalctl _UID=608 -b --no-pager 2>/dev/null | grep -qiE 'beagle|AI Processing Time'; then
        pass "DRP-AI inference ran this boot (result in user-608 journal)"
    elif [ "${payload_present:-0}" -eq 1 ]; then
        fail "DRP-AI inference did NOT run this boot despite payload present (Quadlet auto-start)"
    else
        info "DRP-AI inference not run — no /data/drpai payload (expected on fresh flash; not a defect)"
    fi
fi

# ---------------- 14. network (systemd-networkd) ----------------

section "Network (systemd-networkd)"

# networkd owns DHCP on the board's uplink (EDGE_UPLINK, from the shipped
# unit); unmanaged interfaces are reserved for the kernel netboot path.
if systemctl is-active systemd-networkd.service >/dev/null 2>&1; then
    pass "systemd-networkd active"
else
    fail "systemd-networkd inactive — no network manager running (NetworkManager was removed)"
fi

if command -v networkctl >/dev/null 2>&1; then
    # Parse `networkctl list` columns (IDX LINK TYPE OPERATIONAL SETUP) — robust
    # vs. parsing the prose of `networkctl status`.
    up_op=$(networkctl --no-legend list 2>/dev/null | awk -v i="${EDGE_UPLINK}" '$2==i{print $4}')
    if [ "${up_op}" = "routable" ]; then
        pass "${EDGE_UPLINK} routable"
    elif [ -z "$(ip -o link show "${EDGE_UPLINK}" 2>/dev/null)" ]; then
        fail "uplink '${EDGE_UPLINK}' (from the shipped unit) does not exist — interface naming differs from the board include (links: $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | tr '\n' ' '))"
    else
        fail "${EDGE_UPLINK} not routable (operational='${up_op:-absent}') — DHCP uplink down"
    fi
    for i in ${EDGE_UNMANAGED}; do
        i_setup=$(networkctl --no-legend list 2>/dev/null | awk -v i="${i}" '$2==i{print $5}')
        if [ "${i_setup}" = "unmanaged" ]; then
            pass "${i} unmanaged (as configured for netboot)"
        else
            info "${i} setup: ${i_setup:-absent}"
        fi
    done
else
    warn "networkctl absent — cannot inspect link state"
fi

# IPv4 on the uplink — the SSH path on a flashed (non-netboot) image.
up_v4=$(ip -4 -o addr show "${EDGE_UPLINK}" 2>/dev/null | awk '{print $4}' | head -1)
[ -n "${up_v4}" ] && pass "${EDGE_UPLINK} IPv4 ${up_v4}" || fail "${EDGE_UPLINK} has no IPv4 address (DHCP)"

# IPv6 SLAAC on the uplink: confirm an RA-derived global address.
up_v6=$(ip -6 -o addr show "${EDGE_UPLINK}" scope global 2>/dev/null | awk '{print $4}' | head -1)
[ -n "${up_v6}" ] && pass "${EDGE_UPLINK} IPv6 SLAAC ${up_v6}" \
    || warn "${EDGE_UPLINK} no global IPv6 (SLAAC) — if RA expected, drop net.ipv6.conf.all.accept_ra=0"

# WiFi, where the board has it: the link should exist with brcmfmac bound;
# association is operator provisioning, not an image property.
if [ -e /sys/class/net/wlan0 ]; then
    drv=$(basename "$(readlink /sys/class/net/wlan0/device/driver 2>/dev/null)" 2>/dev/null)
    pass "wlan0 present (driver ${drv:-?}; not configured by the image)"
elif [ "${EDGE_MACHINE}" = "raspberrypi5" ]; then
    fail "wlan0 absent on raspberrypi5 — brcmfmac/firmware/regulatory chain did not bring the radio up"
fi

# DNS without resolved: does networkd populate /etc/resolv.conf?
ns=$(awk '/^nameserver /{print $2; exit}' /etc/resolv.conf 2>/dev/null)
if [ -n "${ns}" ]; then
    pass "/etc/resolv.conf nameserver present (${ns})"
else
    warn "/etc/resolv.conf has no nameserver — networkd-without-resolved wrote no DNS; name resolution fails (SSH-by-IP unaffected)"
fi

# ---------------- summary ----------------

printf "\n${C_BLUE}==================== summary ====================${C_RESET}\n"
printf "  ${C_GREEN}PASS:${C_RESET} %d   ${C_YELLOW}WARN:${C_RESET} %d   ${C_RED}FAIL:${C_RESET} %d\n" \
    "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
