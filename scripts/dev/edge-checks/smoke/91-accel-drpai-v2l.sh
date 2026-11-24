# shellcheck shell=bash
# DRP-AI (RZ/V2L): driver bound, render-group nodes, carveout, inference
# Quadlet ran when its /data payload is present.

edge_check accel.drpai-v2l cap:accel:drpai-v2l "Accelerator (drpai-v2l)" chk_accel_drpai

edge_cap_accel_drpai_v2l() { accel_is drpai-v2l; }

chk_accel_drpai() {
    local n l m memtotal_kb payload_present
    # render-group 0660 ownership (edge-drpai-udev) lets the rootless
    # container open the nodes via keep-groups; root:root 0600 breaks it.
    for n in drpai0 udmabuf0; do
        if [ -e "/dev/${n}" ]; then
            l=$(ls -l "/dev/${n}")
            if printf '%s' "${l}" | grep 'root render' >/dev/null; then
                pass "/dev/${n}: $(printf '%s' "${l}" | awk '{print $1, $3":"$4}')"
            else
                fail "/dev/${n} not root:render (rootless passthrough breaks): ${l}"
            fi
        else
            fail "/dev/${n} missing — module installed but driver did not bind"
        fi
    done

    for m in drpai u_dma_buf; do
        lsmod | grep "^${m} " >/dev/null && pass "module ${m} loaded" || fail "module ${m} not loaded"
    done

    # drp_reserved is a static 512 MB carveout on a 2 GB board.
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

    podman_wait_dropin

    # The Quadlet's ConditionPathExists skips cleanly without a payload; a
    # manual run also satisfies this.
    if sudo -n journalctl "_UID=${ECTR_UID}" -b --no-pager 2>/dev/null | grep -iE 'beagle|AI Processing Time' >/dev/null; then
        pass "DRP-AI inference ran this boot (result in user-${ECTR_UID} journal)"
    elif [ "${payload_present}" -eq 1 ]; then
        fail "DRP-AI inference did NOT run this boot despite payload present (Quadlet auto-start)"
    else
        info "DRP-AI inference not run — no /data/drpai payload (expected on fresh flash; not a defect)"
    fi
}
