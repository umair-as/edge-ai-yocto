# shellcheck shell=bash
# DEEPX DX-M1 (Raspberry Pi 5): PCIe endpoint, drivers, dxrtd and its IPC
# socket, rootless group access, inference Quadlet result.

edge_check accel.dxm1 cap:accel:dxm1 "Accelerator (dxm1)" chk_accel_dxm1

edge_cap_accel_dxm1() { accel_is dxm1; }

chk_accel_dxm1() {
    local dx_bdf ctl aspm m dx_pid dx_uid dx_user dx_status dx_unit dx_fps dx_result
    # PCIe endpoint, DEEPX vendor id 1ff4. The bridge is built in and the
    # driver autoloads from the modalias, so an absent endpoint means the
    # card, the slot or the link, not the image.
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
    case "${EDGE_CMDLINE}" in
        *pcie_aspm=off*) pass "kernel cmdline: pcie_aspm=off (BCM2712 + DX-M1 SError guard)" ;;
        *) fail "kernel cmdline lacks pcie_aspm=off — link-state resets panic this board" ;;
    esac
    if sudo -n dmesg 2>/dev/null | grep -iE 'AER:.*(Uncorrect|Correct)ed error' >/dev/null; then
        warn "PCIe AER errors logged this boot (dmesg | grep AER)"
    else
        pass "no PCIe AER errors this boot"
    fi
    for m in dx_dma dxrt_driver; do
        lsmod | grep "^${m} " >/dev/null && pass "module ${m} loaded" || fail "module ${m} not loaded (udev modalias autoload after PCIe enumeration)"
    done
    devnode_mode /dev/dxrt0 'crw-rw----' dxrt 0660 "/dev/dxrt0 missing — dxrt_driver found no device"
    if systemctl is-active dxrtd.service >/dev/null 2>&1; then
        # BusyBox ps has no -C; read the main PID's uid from /proc instead.
        dx_pid=$(systemctl show -p MainPID --value dxrtd.service 2>/dev/null)
        dx_uid=$(awk '/^Uid:/{print $2}' "/proc/${dx_pid:-0}/status" 2>/dev/null)
        dx_user=$(getent passwd "${dx_uid:-}" 2>/dev/null | cut -d: -f1)
        [ "${dx_user}" = "dxrt" ] && pass "dxrtd active as dxrt" || fail "dxrtd active but running as '${dx_user:-?}' (uid ${dx_uid:-?}; expected dxrt)"
    else
        fail "dxrtd.service not active ($(systemctl is-active dxrtd.service 2>/dev/null)) — ConditionPathExistsGlob=/dev/dxrt* unmet, or the daemon failed"
    fi
    # edge-dxm1-runtime's dxrtd RuntimeDirectory override publishes the
    # dynamic-IPC socket at a fixed, bind-mountable path.
    if sudo -n test -S /run/dxrt/ipc.sock 2>/dev/null; then
        pass "dxrtd listening on /run/dxrt/ipc.sock"
    else
        fail "/run/dxrt/ipc.sock missing — dxrtd's RuntimeDirectory override did not take, or the daemon is down"
    fi
    if command -v dxrt-cli >/dev/null 2>&1; then
        # env explicitly: edge-dxrt-env.sh is profile.d-only and this image's
        # sudo PAM stack does not run pam_env.
        dx_status=$(sudo -n env DXRT_DYNAMIC_IPC_ENDPOINT=/run/dxrt/ipc.sock timeout 20 dxrt-cli -s 2>&1 | head -20)
        if printf '%s' "${dx_status}" | grep -iE 'device|firmware|fw' >/dev/null; then
            pass "dxrt-cli -s reports a device"
            printf '%s\n' "${dx_status}" | grep -iE 'device|firmware|fw|version' | head -4 | sed 's/^/        /'
        else
            warn "dxrt-cli -s gave no device report (daemon/firmware handshake): $(printf '%s' "${dx_status}" | head -1)"
        fi
    fi
    ectr_in_group dxrt
    if sudo -n test -f /data/dxm1/bin/run_model 2>/dev/null; then
        pass "/data/dxm1 inference payload present"
        dx_unit=$(ectr_unit_show dxm1-inference.service ActiveState Result ExecMainStatus ConditionResult NRestarts)
        dx_fps=$(sudo -n journalctl "_UID=${ECTR_UID}" -b --no-pager -t dxm1-inference 2>/dev/null | grep -E 'FPS *:' | tail -1 | sed 's/.*FPS *: *//')
        dx_result="ActiveState=$(unit_prop "${dx_unit}" ActiveState) Result=$(unit_prop "${dx_unit}" Result) ExecMainStatus=$(unit_prop "${dx_unit}" ExecMainStatus)"
        case "$(unit_state_class "${dx_unit}")" in
            unreadable) fail "cannot read dxm1-inference.service state (edge-ctr user manager not reachable)" ;;
            condition-unmet) fail "payload present but dxm1-inference.service did not start this boot (start condition unmet)" ;;
            completed)
                if [ -n "${dx_fps}" ]; then
                    pass "DX-M1 inference completed this boot (${dx_fps} FPS)"
                    [ "$(unit_prop "${dx_unit}" NRestarts)" -gt 0 ] 2>/dev/null \
                        && info "started after $(unit_prop "${dx_unit}" NRestarts) restart(s): dxrtd IPC was not ready on the first attempt"
                else
                    fail "dxm1-inference.service exited 0 without a benchmark result (${dx_result})"
                fi ;;
            running) warn "dxm1-inference.service still running or waiting for dxrtd (${dx_result})" ;;
            *) fail "dxm1-inference.service failed (${dx_result})" ;;
        esac
    else
        info "no /data/dxm1 payload — Quadlet skips (expected on a fresh flash; stage runtime libs + model + run_model there to enable)"
    fi
    podman_wait_dropin
}
