# shellcheck shell=bash
# sshd host keys survive slot swaps: live copies match the /data copies.

edge_check persist.ssh-host-keys core "sshd host keys persistence" chk_ssh_host_keys

chk_ssh_host_keys() {
    local kt live persist live_fp
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
}
