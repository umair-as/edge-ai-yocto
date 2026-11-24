# shellcheck shell=bash
# The kernel cmdline came from the signed slot payload: verity root, the
# booted slot, and a verity table naming that slot's device.

edge_check boot.cmdline core "Kernel cmdline (slot payload)" chk_boot_cmdline

chk_boot_cmdline() {
    local slot=${EDGE_SLOT} dmc verity_dev root_hash expect expect_dev
    if [ -n "${slot}" ]; then
        pass "rauc.slot=${slot}"
    else
        fail "no rauc.slot= in cmdline — not booted via a slot FIT"
    fi

    case "${EDGE_CMDLINE}" in
        *root=/dev/dm-0*) pass "root=/dev/dm-0 (dm-verity mapped root)" ;;
        *root=/dev/mmcblk0p*)
            fail "root is a raw partition ($(printf '%s' "${EDGE_CMDLINE}" | grep -o 'root=[^ ]*')) — legacy/unverified boot path taken" ;;
        *) fail "unrecognized root= in cmdline" ;;
    esac

    dmc=$(printf '%s' "${EDGE_CMDLINE}" | sed -n 's/.*dm-mod\.create="\([^"]*\)".*/\1/p')
    if [ -z "${dmc}" ]; then
        fail "no dm-mod.create in cmdline — verity table not passed by FIT DTB"
        return
    fi
    pass "dm-mod.create present"
    case "${dmc}" in
        *" verity "*) pass "dm target is verity" ;;
        *) fail "dm-mod.create target is not verity: ${dmc}" ;;
    esac
    case "${dmc}" in
        *restart_on_corruption*) pass "restart_on_corruption set (corruption triggers reboot + counter fallback)" ;;
        *) fail "restart_on_corruption missing from verity table" ;;
    esac
    verity_dev=$(printf '%s' "${dmc}" | grep -oE '/dev/[a-z0-9]+p[0-9]+' | head -1)
    root_hash=$(printf '%s' "${dmc}" | grep -oE '\b[0-9a-f]{64}\b' | head -1)
    info "backing device: ${verity_dev:-?}  root hash: ${root_hash:-?}"
    # The booted slot's device= in system.conf (a by-rauc-slot link: device
    # names on MBR, partition names on GPT) must resolve to the device the
    # signed table names.
    expect=$(rauc_slot_device "${EDGE_RAUC_CONF}" "${slot}")
    expect=${expect:-/dev/disk/by-rauc-slot/rootfs${slot}}
    expect_dev=$(readlink -f "${expect}" 2>/dev/null || true)
    if [ -n "${expect_dev}" ]; then
        if [ "${verity_dev}" = "${expect_dev}" ]; then
            pass "slot ${slot} maps to ${verity_dev} (= ${expect#/dev/disk/})"
        else
            fail "slot ${slot}: verity backing dev ${verity_dev:-absent} but ${expect#/dev/disk/} -> ${expect_dev}"
        fi
    else
        fail "${expect} missing — edge-slot-udev rules not keyed for this layout"
    fi
    # Without dm-mod.waitfor, dm-init can run before the eMMC partition scan
    # and the boot hangs at "Waiting for root device /dev/dm-0".
    if [ "${EDGE_BOOT_CHAIN}" != uboot ]; then
        case " ${EDGE_CMDLINE} " in
            *" dm-mod.waitfor=${verity_dev} "*|*" dm-mod.waitfor=${verity_dev},"*)
                pass "dm-mod.waitfor names ${verity_dev}" ;;
            *) fail "dm-mod.waitfor does not name ${verity_dev:-the backing device} — dm-init races the partition scan" ;;
        esac
    fi
}
