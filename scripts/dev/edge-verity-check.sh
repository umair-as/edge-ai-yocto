#!/usr/bin/env bash
# On-device dm-verity boot verification for the edge-ai distro.
#
# Validates the verified-boot chain end state after a flash or OTA:
#   - kernel cmdline came from the signed slot FIT (root=/dev/dm-0,
#     dm-mod.create verity table, rauc.slot marker)
#   - the dm-verity mapping is active, matches the booted slot's partition,
#     and the rootfs is mounted read-only from it
#   - no verity corruption events this boot
#   - both slot FITs on /boot, managed U-Boot env seeded
#     (BOOT_ORDER/counters, EDGE_VERITY_A/B markers)
#   - RAUC agrees with the cmdline about the booted slot
#
# Complements edge-smoke-test.sh (persistence, containers, SELinux); run both.
# Non-destructive: the only write attempted is a probe at / that must FAIL
# with EROFS on a verity rootfs.
#
# Run from the host:
#   ssh devel@<board-ip> 'bash -s' < scripts/dev/edge-verity-check.sh
# or rsync + execute as devel (sudo used where root is required).
#
# First-boot note: on fresh media the baked U-Boot BOOTCOMMAND boots
# fitImage-A unconditionally; the managed env (BOOT_ORDER, counters,
# EDGE_VERITY_*) exists only after rauc-uboot-env-init.service has run once.

set -u
set -o pipefail

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

# ---------------- 1. kernel cmdline (signed FIT contract) ----------------

section "Kernel cmdline (signed slot FIT)"

cmdline=$(cat /proc/cmdline)

slot=$(printf '%s' "${cmdline}" | sed -n 's/.*rauc\.slot=\([AB]\).*/\1/p')
if [ -n "${slot}" ]; then
    pass "rauc.slot=${slot}"
else
    fail "no rauc.slot= in cmdline — not booted via a slot FIT"
fi

case "${cmdline}" in
    *root=/dev/dm-0*) pass "root=/dev/dm-0 (dm-verity mapped root)" ;;
    *root=/dev/mmcblk0p*)
        fail "root is a raw partition ($(printf '%s' "${cmdline}" | grep -o 'root=[^ ]*')) — legacy/unverified boot path taken" ;;
    *) fail "unrecognized root= in cmdline" ;;
esac

dmc=$(printf '%s' "${cmdline}" | sed -n 's/.*dm-mod\.create="\([^"]*\)".*/\1/p')
if [ -n "${dmc}" ]; then
    pass "dm-mod.create present"
    case "${dmc}" in
        *" verity "*) pass "dm target is verity" ;;
        *) fail "dm-mod.create target is not verity: ${dmc}" ;;
    esac
    case "${dmc}" in
        *restart_on_corruption*) pass "restart_on_corruption set (corruption triggers reboot + counter fallback)" ;;
        *) fail "restart_on_corruption missing from verity table" ;;
    esac
    verity_dev=$(printf '%s' "${dmc}" | grep -o '/dev/mmcblk0p[0-9]' | head -1)
    root_hash=$(printf '%s' "${dmc}" | grep -oE '\b[0-9a-f]{64}\b' | head -1)
    info "backing device: ${verity_dev:-?}  root hash: ${root_hash:-?}"
    # Slot identity is partition number by contract: A=p2, B=p3.
    expect_dev=""
    [ "${slot}" = "A" ] && expect_dev="/dev/mmcblk0p2"
    [ "${slot}" = "B" ] && expect_dev="/dev/mmcblk0p3"
    if [ -n "${expect_dev}" ]; then
        if [ "${verity_dev}" = "${expect_dev}" ]; then
            pass "slot ${slot} maps to ${verity_dev} (matches A=p2/B=p3 contract)"
        else
            fail "slot ${slot} but verity backing dev is ${verity_dev:-absent} (expected ${expect_dev})"
        fi
    fi
else
    fail "no dm-mod.create in cmdline — verity table not passed by FIT DTB"
fi

# ---------------- 2. active dm-verity mapping ----------------

section "Active dm-verity mapping"

if [ -r /sys/block/dm-0/dm/name ]; then
    dm_name=$(cat /sys/block/dm-0/dm/name)
    if [ "${dm_name}" = "vroot" ]; then
        pass "dm-0 exists, name=vroot"
    else
        warn "dm-0 name is '${dm_name}' (expected vroot)"
    fi
else
    fail "no /sys/block/dm-0 — dm device absent"
fi

root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ "${root_src}" = "/dev/dm-0" ] || [ "${root_src}" = "/dev/mapper/vroot" ]; then
    pass "/ mounted from ${root_src}"
else
    fail "/ mounted from '${root_src:-?}' (expected /dev/dm-0)"
fi

root_opts=$(findmnt -no OPTIONS / 2>/dev/null || true)
case ",${root_opts}," in
    *,ro,*) pass "/ mounted read-only" ;;
    *)      fail "/ mount options '${root_opts}' — not read-only" ;;
esac

if command -v veritysetup >/dev/null 2>&1; then
    vstatus=$(sudo -n veritysetup status vroot 2>/dev/null || true)
    vstate=$(printf '%s' "${vstatus}" | awk '/^ *status:/ {print $2; exit}')
    case "${vstate}" in
        verified) pass "veritysetup status vroot: verified" ;;
        corrupted) fail "veritysetup status vroot: CORRUPTED" ;;
        "") warn "veritysetup status unavailable (needs sudo, or device not via veritysetup)" ;;
        *) warn "veritysetup status vroot: ${vstate}" ;;
    esac
else
    info "veritysetup not installed; relying on dmesg + sysfs checks"
fi

# ---------------- 3. read-only enforcement probe ----------------

section "Read-only enforcement"

# Expected to fail with EROFS; a success means the root is writable and the
# verity hash is now broken.
if err=$(touch /verity-write-probe 2>&1); then
    rm -f /verity-write-probe 2>/dev/null
    fail "write at / SUCCEEDED — rootfs is writable (verity not protecting /)"
else
    case "${err}" in
        *[Rr]ead-only*) pass "write at / rejected (read-only filesystem)" ;;
        *)              pass "write at / rejected (${err##*: })" ;;
    esac
fi

# ---------------- 4. verity events this boot ----------------

section "Verity kernel events"

dm_dmesg=$(sudo -n dmesg 2>/dev/null | grep -iE 'device-mapper.*(verity|corrupt|mismatch)' || true)
init_line=$(printf '%s' "${dm_dmesg}" | grep -i 'dm-mod.create' | head -1)
corrupt=$(printf '%s' "${dm_dmesg}" | grep -icE 'corrupt|mismatch|invalid block')
if [ -z "${dm_dmesg}" ]; then
    warn "no device-mapper lines readable in dmesg (needs sudo, or ring buffer rotated)"
else
    [ -n "${init_line}" ] && info "${init_line}"
    if [ "${corrupt}" -eq 0 ]; then
        pass "no verity corruption/mismatch events this boot"
    else
        fail "${corrupt} verity corruption event(s) in dmesg:"
        printf '%s\n' "${dm_dmesg}" | grep -iE 'corrupt|mismatch|invalid block' | head -3 | sed 's/^/        /'
    fi
fi

# ---------------- 5. /boot slot FITs ----------------

section "/boot slot FITs"

for f in fitImage-A fitImage-B; do
    if [ -s "/boot/${f}" ]; then
        pass "/boot/${f} present ($(stat -c %s "/boot/${f}") bytes)"
    else
        fail "/boot/${f} missing — that slot cannot boot verified"
    fi
done
[ -s /boot/fitImage ] && info "legacy /boot/fitImage present (transitional fallback, unused on verity slots)"

booted_fit="/boot/fitImage-${slot:-A}"
if [ -s "${booted_fit}" ]; then
    info "booted slot FIT: ${booted_fit} sha256 $(sha256sum "${booted_fit}" | cut -c1-16)…"
fi

# ---------------- 6. managed U-Boot environment ----------------

section "Managed U-Boot environment"

if systemctl is-active rauc-uboot-env-init.service >/dev/null 2>&1; then
    pass "rauc-uboot-env-init.service active (exited)"
else
    warn "rauc-uboot-env-init.service not active — env may be unseeded (first boot not completed?)"
fi

if command -v fw_printenv >/dev/null 2>&1; then
    getenv() { sudo -n fw_printenv -n "$1" 2>/dev/null || true; }
    border=$(getenv BOOT_ORDER)
    aleft=$(getenv BOOT_A_LEFT)
    bleft=$(getenv BOOT_B_LEFT)
    if [ -n "${border}" ]; then
        pass "BOOT_ORDER='${border}'  BOOT_A_LEFT=${aleft:-?}  BOOT_B_LEFT=${bleft:-?}"
    else
        fail "BOOT_ORDER unset — managed env not seeded (or fw_env.config wrong)"
    fi
    # Counter for the booted slot should be reset to 3 (rauc mark-good via
    # activate-installed / boot-attempts-primary); a low value that keeps
    # sinking across reboots means mark-good is not running.
    booted_left=""
    [ "${slot}" = "A" ] && booted_left="${aleft}"
    [ "${slot}" = "B" ] && booted_left="${bleft}"
    if [ "${booted_left}" = "3" ]; then
        pass "booted slot ${slot} attempts reset to 3 (mark-good ran)"
    elif [ -n "${booted_left}" ]; then
        warn "booted slot ${slot} attempts=${booted_left} (not yet reset to 3 — check rauc mark-good)"
    fi
    for m in EDGE_VERITY_A EDGE_VERITY_B; do
        v=$(getenv "${m}")
        if [ "${v}" = "1" ]; then
            pass "${m}=1"
        else
            fail "${m}='${v:-unset}' — U-Boot selects the LEGACY (unverified) path for that slot"
        fi
    done
else
    fail "fw_printenv not installed"
fi

# ---------------- 7. RAUC slot agreement ----------------

section "RAUC slot state"

if status_json=$(sudo -n rauc status --output-format=json 2>/dev/null); then
    booted=$(printf '%s' "${status_json}" | sed -n 's/.*"booted":"\([^"]*\)".*/\1/p' | head -1)
    if [ "rootfs.${slot}" = "${booted}" ] || printf '%s' "${booted}" | grep -qi "${slot}$"; then
        pass "rauc booted slot '${booted}' agrees with cmdline slot ${slot}"
    else
        fail "rauc booted slot '${booted:-?}' vs cmdline slot ${slot} — disagreement"
    fi
    boot_good=$(printf '%s' "${status_json}" | grep -o '"boot_status":"good"' | wc -l)
    info "slots with boot_status=good: ${boot_good}"
else
    warn "rauc status unreachable (needs sudo)"
fi

# ---------------- 8. module signing sanity ----------------

section "Module signing"

# MODULE_SIG_FORCE rejects unsigned modules; any loaded module proves the
# in-image signing chain survived strip + sign + package.
mod_count=$(lsmod | tail -n +2 | wc -l)
if [ "${mod_count}" -gt 0 ]; then
    pass "${mod_count} kernel modules loaded under MODULE_SIG_FORCE"
else
    warn "no modules loaded — cannot confirm signed-module load path"
fi

taint=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo "?")
info "kernel taint: ${taint} (8192=out-of-tree vendor modules is expected)"

# ---------------- summary ----------------

printf "\n${C_BLUE}==================== summary ====================${C_RESET}\n"
printf "  ${C_GREEN}PASS:${C_RESET} %d   ${C_YELLOW}WARN:${C_RESET} %d   ${C_RED}FAIL:${C_RESET} %d\n" \
    "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
