# shellcheck shell=bash
# Hexagon NPU (VENTUNO Q): compute DSP up, FastRPC node and DMA-heap ACL for
# the fastrpc group, QAIRT platform validator, inference Quadlet result.

edge_check accel.qnn-htp-v75 cap:accel:qnn-htp-v75 "Accelerator (qnn-htp-v75)" chk_accel_qnn

edge_cap_accel_qnn_htp_v75() { accel_is qnn-htp-v75; }

chk_accel_qnn() {
    local r cdsp_state="" pv qn_unit qn_ms
    for r in /sys/class/remoteproc/remoteproc*; do
        [ "$(cat "${r}/name" 2>/dev/null)" = "cdsp" ] && cdsp_state=$(cat "${r}/state" 2>/dev/null)
    done
    [ "${cdsp_state}" = "running" ] \
        && pass "compute DSP (cdsp) remoteproc running" \
        || fail "cdsp remoteproc not running (state: ${cdsp_state:-absent})"
    # libcdsprpc opens the node read-only, so group read is enough.
    devnode_mode /dev/fastrpc-cdsp 'crw-r-----' fastrpc 0640 "/dev/fastrpc-cdsp missing — the fastrpc driver did not bind the compute DSP"
    if command -v getfacl >/dev/null 2>&1; then
        getfacl -p /dev/dma_heap/system 2>/dev/null | grep -x 'group:fastrpc:rw-' >/dev/null \
            && pass "/dev/dma_heap/system grants group fastrpc rw (ACL)" \
            || fail "/dev/dma_heap/system lacks the g:fastrpc ACL — the DSP cannot map buffers"
    else
        warn "getfacl absent — dma_heap ACL not inspected"
    fi
    ectr_in_group fastrpc
    # The DSP runs a calculator skel shipped with QAIRT: proves FastRPC, the
    # skel search path and the HTP v75 core with no model. Run as edge-ctr:
    # the login user is not in fastrpc and fails device creation by design.
    if command -v qnn-platform-validator >/dev/null 2>&1; then
        pv=$(sudo -n -u edge-ctr sh -c 'd=$(mktemp -d) && cd "$d" && timeout 60 qnn-platform-validator \
                 --backend dsp --testBackend --coreVersion --targetPath "$d"; rc=$?; cd / && rm -rf "$d"; exit $rc' \
                 2>&1 | tr -d '\r')
        if printf '%s' "${pv}" | grep -q 'Unit Test on the backend DSP: Passed'; then
            pass "qnn-platform-validator: DSP unit test passed ($(printf '%s' "${pv}" | sed -n 's/^Core Version of the backend DSP: //p'))"
        else
            fail "qnn-platform-validator DSP unit test did not pass: $(printf '%s' "${pv}" | grep -m1 -iE 'error|fail' )"
        fi
    else
        fail "qnn-platform-validator missing — qairt-sdk not installed"
    fi
    if sudo -n test -f /data/qnn-htp/model/model.bin 2>/dev/null; then
        pass "/data/qnn-htp inference payload present"
        qn_unit=$(ectr_unit_show qnn-htp-inference.service ActiveState Result ExecMainStatus ConditionResult)
        qn_ms=$(sudo -n journalctl "_UID=${ECTR_UID}" -b --no-pager -o cat SYSLOG_IDENTIFIER=systemd-qnn-htp-inference 2>/dev/null \
                    | sed -n 's/^ *NetRun: \([0-9]*\) us$/\1/p' | tail -1)
        case "$(unit_state_class "${qn_unit}")" in
            unreadable) fail "cannot read qnn-htp-inference.service state (edge-ctr user manager not reachable)" ;;
            condition-unmet) fail "payload present but qnn-htp-inference.service did not start this boot (start condition unmet)" ;;
            completed) pass "QNN HTP inference completed this boot (NetRun average ${qn_ms:-?} us)" ;;
            running) warn "qnn-htp-inference.service still running" ;;
            *) fail "qnn-htp-inference.service failed (ActiveState=$(unit_prop "${qn_unit}" ActiveState) Result=$(unit_prop "${qn_unit}" Result) ExecMainStatus=$(unit_prop "${qn_unit}" ExecMainStatus))" ;;
        esac
    else
        info "no /data/qnn-htp payload — Quadlet skips (expected on a fresh flash; stage model/model.bin + inputs there to enable)"
    fi
}
