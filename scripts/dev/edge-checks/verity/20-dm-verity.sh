# shellcheck shell=bash
# The dm-verity mapping is active and / is mounted read-only from it, and a
# write at / is refused.

edge_check boot.dm-verity core "Active dm-verity mapping" chk_dm_verity
edge_check boot.read-only core "Read-only enforcement" chk_read_only
edge_check boot.verity-events core "Verity kernel events" chk_verity_events

chk_dm_verity() {
    local dm_name root_src root_opts vstatus vstate
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
}

chk_read_only() {
    local err
    # Must fail with EROFS; a success means the root is writable and the
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
}

chk_verity_events() {
    local dm_dmesg init_line corrupt
    dm_dmesg=$(sudo -n dmesg 2>/dev/null | grep -iE 'device-mapper.*(verity|corrupt|mismatch)' || true)
    init_line=$(printf '%s' "${dm_dmesg}" | grep -i 'dm-mod.create' | head -1)
    corrupt=$(printf '%s' "${dm_dmesg}" | grep -icE 'corrupt|mismatch|invalid block')
    if [ -z "${dm_dmesg}" ]; then
        warn "no device-mapper lines readable in dmesg (needs sudo, or ring buffer rotated)"
        return
    fi
    [ -n "${init_line}" ] && info "${init_line}"
    if [ "${corrupt}" -eq 0 ]; then
        pass "no verity corruption/mismatch events this boot"
    else
        fail "${corrupt} verity corruption event(s) in dmesg:"
        printf '%s\n' "${dm_dmesg}" | grep -iE 'corrupt|mismatch|invalid block' | head -3 | sed 's/^/        /'
    fi
}
