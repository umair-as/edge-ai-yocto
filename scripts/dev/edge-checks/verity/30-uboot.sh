# shellcheck shell=bash
# U-Boot boot chain (RAUC bootloader=uboot): a signed FIT per slot on /boot,
# the FIT trust anchor, and the RAUC-managed U-Boot environment.

edge_check boot.uboot-fits cap:boot:uboot "/boot slot FITs" chk_uboot_fits
edge_check boot.fit-anchor cap:boot:uboot "FIT trust anchor" chk_fit_anchor
edge_check boot.uboot-env cap:boot:uboot "Managed U-Boot environment" chk_uboot_env

edge_cap_boot_uboot() {
    [ "${EDGE_BOOT_CHAIN}" = uboot ] && return 0
    echo "boot chain is ${EDGE_BOOT_CHAIN}"
    return 1
}

chk_uboot_fits() {
    local s f booted_fit
    for s in ${EDGE_SLOTS}; do
        f=fitImage-${s}
        if [ -s "/boot/${f}" ]; then
            pass "/boot/${f} present ($(stat -c %s "/boot/${f}") bytes)"
        else
            fail "/boot/${f} missing — that slot cannot boot verified"
        fi
    done
    [ -s /boot/fitImage ] && info "legacy /boot/fitImage present (transitional fallback, unused on verity slots)"

    booted_fit="/boot/fitImage-${EDGE_SLOT:-A}"
    if [ -s "${booted_fit}" ]; then
        info "booted slot FIT: ${booted_fit} sha256 $(sha256sum "${booted_fit}" | cut -c1-16)…"
    fi
}

chk_fit_anchor() {
    local anchor algo memtotal_kb
    case "${EDGE_MACHINE}" in
        raspberrypi5)
            # The firmware hands the board DTB on /boot to U-Boot as its
            # control FDT; the FIT public key must be in that file.
            anchor=/boot/bcm2712-rpi-5-b.dtb
            if [ -s "${anchor}" ] && command -v fdtget >/dev/null 2>&1; then
                algo=$(fdtget "${anchor}" /signature/key-edge-fit-dev algo 2>/dev/null || true)
                [ -n "${algo}" ] && pass "${anchor} carries /signature/key-edge-fit-dev (${algo})" \
                                 || fail "${anchor} has no /signature/key-edge-fit-dev — U-Boot boots FITs unverified"
            else
                warn "${anchor} or fdtget unavailable; trust anchor not inspected"
            fi
            # U-Boot rewrites the FIT DTB's memory node from the firmware DTB;
            # the mainline placeholder is 640 MiB, so the board's real RAM
            # proves the fixup path worked.
            memtotal_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
            if [ "${memtotal_kb}" -gt 2000000 ]; then
                pass "MemTotal ${memtotal_kb} kB — U-Boot memory fixup reached the FIT DTB"
            else
                fail "MemTotal ${memtotal_kb} kB — kernel is running on the DTS placeholder memory node (U-Boot fixup missing)"
            fi
            ;;
        smarc-rzv2l)
            info "anchor is the signed control DTB inside the FIP (raw MMC), not a file on /boot; verified by the build's edge_check_fit_anchor" ;;
        *)
            info "no anchor check for MACHINE '${EDGE_MACHINE:-?}'" ;;
    esac
}

uboot_getenv() { sudo -n fw_printenv -n "$1" 2>/dev/null || true; }

chk_uboot_env() {
    local border aleft bleft booted_left m v
    if systemctl is-active rauc-uboot-env-init.service >/dev/null 2>&1; then
        pass "rauc-uboot-env-init.service active (exited)"
    else
        warn "rauc-uboot-env-init.service not active — env may be unseeded (first boot not completed?)"
    fi

    if ! command -v fw_printenv >/dev/null 2>&1; then
        fail "fw_printenv not installed"
        return
    fi
    border=$(uboot_getenv BOOT_ORDER)
    aleft=$(uboot_getenv BOOT_A_LEFT)
    bleft=$(uboot_getenv BOOT_B_LEFT)
    if [ -n "${border}" ]; then
        pass "BOOT_ORDER='${border}'  BOOT_A_LEFT=${aleft:-?}  BOOT_B_LEFT=${bleft:-?}"
    else
        fail "BOOT_ORDER unset — managed env not seeded (or fw_env.config wrong)"
    fi
    # rauc mark-good resets the booted slot's counter to 3; a value that keeps
    # sinking across reboots means mark-good is not running.
    booted_left=""
    [ "${EDGE_SLOT}" = "A" ] && booted_left="${aleft}"
    [ "${EDGE_SLOT}" = "B" ] && booted_left="${bleft}"
    if [ "${booted_left}" = "3" ]; then
        pass "booted slot ${EDGE_SLOT} attempts reset to 3 (mark-good ran)"
    elif [ -n "${booted_left}" ]; then
        warn "booted slot ${EDGE_SLOT} attempts=${booted_left} (not yet reset to 3 — check rauc mark-good)"
    fi
    for m in ${EDGE_SLOTS}; do
        m=EDGE_VERITY_${m}
        v=$(uboot_getenv "${m}")
        if [ "${v}" = "1" ]; then
            pass "${m}=1"
        else
            fail "${m}='${v:-unset}' — U-Boot selects the LEGACY (unverified) path for that slot"
        fi
    done
}
