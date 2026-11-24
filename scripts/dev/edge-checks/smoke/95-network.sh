# shellcheck shell=bash
# Networking: systemd-networkd owns DHCP on the uplink named by the shipped
# unit; unmanaged links are reserved for the kernel netboot path.

edge_check net.networkd core "Network (systemd-networkd)" chk_network

chk_network() {
    local links up_op i i_setup up_v4 up_v6 drv ns
    if systemctl is-active systemd-networkd.service >/dev/null 2>&1; then
        pass "systemd-networkd active"
    else
        fail "systemd-networkd inactive — no network manager running (NetworkManager was removed)"
    fi

    if command -v networkctl >/dev/null 2>&1; then
        links=$(networkctl --no-legend list 2>/dev/null)
        up_op=$(printf '%s\n' "${links}" | netlink_field "${EDGE_UPLINK}" 4)
        if [ "${up_op}" = "routable" ]; then
            pass "${EDGE_UPLINK} routable"
        elif [ -z "$(ip -o link show "${EDGE_UPLINK}" 2>/dev/null)" ]; then
            fail "uplink '${EDGE_UPLINK}' (from the shipped unit) does not exist — interface naming differs from the board include (links: $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | tr '\n' ' '))"
        else
            fail "${EDGE_UPLINK} not routable (operational='${up_op:-absent}') — DHCP uplink down"
        fi
        for i in ${EDGE_UNMANAGED}; do
            i_setup=$(printf '%s\n' "${links}" | netlink_field "${i}" 5)
            if [ "${i_setup}" = "unmanaged" ]; then
                pass "${i} unmanaged (as configured for netboot)"
            else
                info "${i} setup: ${i_setup:-absent}"
            fi
        done
    else
        warn "networkctl absent — cannot inspect link state"
    fi

    up_v4=$(ip -4 -o addr show "${EDGE_UPLINK}" 2>/dev/null | awk '{print $4}' | head -1)
    [ -n "${up_v4}" ] && pass "${EDGE_UPLINK} IPv4 ${up_v4}" || fail "${EDGE_UPLINK} has no IPv4 address (DHCP)"

    up_v6=$(ip -6 -o addr show "${EDGE_UPLINK}" scope global 2>/dev/null | awk '{print $4}' | head -1)
    [ -n "${up_v6}" ] && pass "${EDGE_UPLINK} IPv6 SLAAC ${up_v6}" \
        || warn "${EDGE_UPLINK} no global IPv6 (SLAAC) — if RA expected, drop net.ipv6.conf.all.accept_ra=0"

    # WiFi on boards that have it: the link exists with its driver bound;
    # association is operator provisioning, not an image property.
    if [ -e /sys/class/net/wlan0 ]; then
        drv=$(basename "$(readlink /sys/class/net/wlan0/device/driver 2>/dev/null)" 2>/dev/null)
        pass "wlan0 present (driver ${drv:-?}; not configured by the image)"
    elif [ "${EDGE_MACHINE}" = "raspberrypi5" ]; then
        fail "wlan0 absent on raspberrypi5 — brcmfmac/firmware/regulatory chain did not bring the radio up"
    fi

    # Without systemd-resolved, networkd must populate /etc/resolv.conf.
    ns=$(awk '/^nameserver /{print $2; exit}' /etc/resolv.conf 2>/dev/null)
    if [ -n "${ns}" ]; then
        pass "/etc/resolv.conf nameserver present (${ns})"
    else
        warn "/etc/resolv.conf has no nameserver — networkd-without-resolved wrote no DNS; name resolution fails (SSH-by-IP unaffected)"
    fi
}
