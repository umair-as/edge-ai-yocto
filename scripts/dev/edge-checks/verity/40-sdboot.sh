# shellcheck shell=bash
# UEFI boot chain (RAUC bootloader=custom, ADR-0016 §6): systemd-boot booted
# the slot's ESP entry, no variable pins a slot, RAUC alone confirms a boot.

edge_check boot.sdboot cap:boot:sdboot "systemd-boot slot entries" chk_sdboot

edge_cap_boot_sdboot() {
    [ "${EDGE_BOOT_CHAIN}" = sdboot ] && return 0
    echo "boot chain is ${EDGE_BOOT_CHAIN}"
    return 1
}

LOADER_GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f

# efivar <name>: a systemd loader variable, UTF-16 text without NULs.
efivar() {
    local f=/sys/firmware/efi/efivars/$1-${LOADER_GUID}
    [ -r "$f" ] && tail -c +5 "$f" | tr -d '\000'
}

chk_sdboot() {
    local backend=/usr/libexec/edge-sdboot-backend slot=${EDGE_SLOT} loader_info selected v primary s st
    loader_info=$(efivar LoaderInfo)
    case "${loader_info}" in
        systemd-boot*) pass "booted through ${loader_info}" ;;
        *) fail "LoaderInfo '${loader_info:-unset}' — not booted through systemd-boot" ;;
    esac
    selected=$(efivar LoaderEntrySelected)
    case "${selected}" in
        edge-*-"${slot,,}".efi) pass "LoaderEntrySelected ${selected} is slot ${slot}" ;;
        *) fail "LoaderEntrySelected '${selected:-unset}' is not slot ${slot:-?}'s entry" ;;
    esac
    for v in LoaderEntryDefault LoaderEntryOneShot; do
        if [ -e "/sys/firmware/efi/efivars/${v}-${LOADER_GUID}" ]; then
            fail "${v} is set: it overrides loader.conf and pins one slot"
        else
            pass "${v} unset"
        fi
    done
    if ls /sys/firmware/efi/efivars/BootNext-* >/dev/null 2>&1; then
        fail "BootNext is set — this firmware crashes on a BootNext boot (ADR-0016)"
    else
        pass "BootNext unset"
    fi
    if primary=$(sudo -n "${backend}" get-primary 2>&1); then
        pass "primary slot ${primary}"
        for s in ${EDGE_SLOTS}; do
            if st=$(sudo -n "${backend}" get-state "${s}" 2>&1); then
                info "slot ${s}: ${st}"
            else
                fail "slot ${s}: ${st}"
            fi
        done
    else
        fail "${backend} get-primary: ${primary}"
    fi
    ls /boot/EFI/Linux 2>/dev/null | sed 's/^/        /'
    case "$(systemctl is-enabled systemd-bless-boot.service 2>/dev/null)" in
        masked) pass "systemd-bless-boot masked (RAUC alone confirms a slot)" ;;
        *) fail "systemd-bless-boot not masked: it would confirm a trial boot without RAUC" ;;
    esac
    case "$(systemctl is-enabled systemd-boot-update.service 2>/dev/null)" in
        disabled|masked) pass "systemd-boot-update off (the ESP loader is not replaced in place)" ;;
        *) fail "systemd-boot-update enabled: bootctl update would rewrite the ESP's only loader" ;;
    esac
    if [ -r /boot/EFI/BOOT/BOOTAA64.EFI ]; then
        if [ "$(sha256sum < /boot/EFI/BOOT/BOOTAA64.EFI)" = "$(sha256sum < /usr/lib/systemd/boot/efi/systemd-bootaa64.efi)" ]; then
            pass "ESP loader is this image's systemd-boot"
        else
            warn "ESP loader differs from this image's systemd-boot (an update does not replace the loader)"
        fi
    else
        fail "/boot/EFI/BOOT/BOOTAA64.EFI missing: no boot path"
    fi
    case "$(systemctl show -p Result --value rauc-mark-good.service 2>/dev/null)" in
        success) pass "rauc-mark-good.service succeeded" ;;
        *) fail "rauc-mark-good.service did not succeed — journalctl -b -u rauc-mark-good" ;;
    esac
}
