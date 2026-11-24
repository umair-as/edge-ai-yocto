# shellcheck shell=bash
# /data: mounted, grown once on first boot, no fstab duplicates, no reserve.

edge_check storage.data core "/data partition + fstab" chk_data

chk_data() {
    local fstab_dups data_src reserve
    if findmnt /data >/dev/null 2>&1; then
        pass "/data is mounted ($(findmnt -no SOURCE /data))"
        info "/data usage: $(df -h /data | awk 'NR==2{print $3" used / "$2" total ("$5" full)"}')"
    else
        fail "/data is NOT mounted — every persistence bind will fail"
    fi

    if findmnt /boot >/dev/null 2>&1; then
        pass "/boot is mounted ($(findmnt -no SOURCE /boot))"
    else
        warn "/boot is not mounted (bundle-hook may have unmounted post-install)"
    fi

    # WIC's update_fstab() appends /dev/mmcblk0pN entries on top of the
    # base-files fstab unless edge-image.bbclass passes --no-fstab-update;
    # duplicates make systemd-fstab-generator log "Duplicate entry".
    fstab_dups=$(awk '!/^\s*(#|$)/ {print $2}' /etc/fstab | sort | uniq -d)
    if [ -z "${fstab_dups}" ]; then
        pass "/etc/fstab has no duplicate mountpoints"
    else
        fail "/etc/fstab has duplicate mountpoint(s): ${fstab_dups}"
    fi
    if ! journalctl -b 0 -u systemd-fstab-generator --no-pager 2>/dev/null \
           | grep -i 'duplicate entry' >/dev/null; then
        pass "systemd-fstab-generator has no 'Duplicate entry' errors this boot"
    else
        fail "systemd-fstab-generator logged 'Duplicate entry' — WIC dup-fstab trap struck"
    fi

    # The grow step ends with `tune2fs -m 0`: no reserved blocks on /data.
    if command -v dumpe2fs >/dev/null 2>&1; then
        data_src=$(findmnt -no SOURCE /data 2>/dev/null || true)
        if [ -b "${data_src}" ]; then
            reserve=$(sudo -n dumpe2fs -h "${data_src}" 2>/dev/null \
                | awk -F: '/Reserved block count/ {gsub(/ /, "", $2); print $2; exit}')
            if [ "${reserve}" = "0" ]; then
                pass "/data reserved-blocks = 0 (tune2fs -m 0 ran)"
            elif [ -n "${reserve}" ]; then
                warn "/data reserved-blocks = ${reserve} (tune2fs -m 0 not yet applied)"
            else
                warn "could not read /data reserved-blocks (sudo dumpe2fs returned nothing)"
            fi
        fi
    fi

    # edge-grow-data.service grows /data once, on the first boot of a fresh
    # flash (gated by /boot/.edge-data-grown): look across all boots.
    if journalctl -u edge-grow-data.service --no-pager 2>/dev/null | grep -iE '✓|▶|⏭|growth complete' >/dev/null; then
        pass "edge-grow-data.service ran (/data growth logged)"
    elif [ "$(systemctl is-active edge-grow-data.service 2>/dev/null)" = "active" ]; then
        pass "edge-grow-data.service active (exited) — /data growth"
    else
        warn "edge-grow-data.service log absent or unparsed"
    fi
}
