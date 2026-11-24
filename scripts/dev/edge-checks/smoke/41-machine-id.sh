# shellcheck shell=bash
# /etc/machine-id is captured to /data and restored before services start.

edge_check persist.machine-id core "machine-id persistence" chk_machine_id

chk_machine_id() {
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

    # The early unit restores the id from the raw data device before journald.
    if systemctl is-active edge-machine-id-early.service >/dev/null 2>&1; then
        pass "edge-machine-id-early.service active (exited)"
        if journalctl -b -u edge-machine-id-early.service --no-pager 2>/dev/null | grep "restored machine-id" >/dev/null; then
            pass "machine-id restored from the raw data device before services started"
        else
            info "no early restore this boot (first boot, or id already matched)"
        fi
    else
        fail "edge-machine-id-early.service did not run"
    fi
}
