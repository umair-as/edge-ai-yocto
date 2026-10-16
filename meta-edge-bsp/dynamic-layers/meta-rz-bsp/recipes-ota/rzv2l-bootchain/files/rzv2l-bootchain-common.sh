# shellcheck shell=bash disable=SC2034
# SPDX-License-Identifier: MIT
#
# Shared guards for the RZ/V2L eMMC bootchain path: the RAUC boot-emmc slot
# "bootloader.0" writes BL2 + FIP into the inactive eMMC boot partition and then
# flips EXT_CSD[179]. Sourced by rzv2l-bootchain-preinstall, -slot-hook and
# -authorize; it defines functions only.
#
# Bundle image layout (one file, written from byte 0 of the boot partition):
#   0x0 .. BL2_OFFSET-1   zero
#   BL2_OFFSET            bl2_bp_mmc (boot parameters + BL2), AA55 at +0x1FE
#   FIP_OFFSET            FIP (ToC name 0xAA640001)
# The ROM reads BL2 from the boot partition EXT_CSD[179] enables and never tries
# the other one; BL2 reads the FIP from the same partition at the offset of its
# TF-A pin.

RZB_MMC_DEV=${RZB_MMC_DEV:-@MMC_DEV@}
RZB_BL2_OFFSET=$(( ${RZB_BL2_OFFSET:-@BL2_OFFSET@} ))
RZB_FIP_OFFSET=$(( ${RZB_FIP_OFFSET:-@FIP_OFFSET@} ))
# "<tf-a pin>:<fip offset>" pairs. A bundle whose pin is absent, or whose FIP
# offset differs from its pin's entry, is refused.
RZB_TFA_FIP_LAYOUT=${RZB_TFA_FIP_LAYOUT:-@TFA_FIP_LAYOUT@}
RZB_FORMAT="rzv2l-emmc-bootpart-v1"
RZB_CLASS="bootloader"
RZB_RUN_DIR=${RZB_RUN_DIR:-/run/rzv2l-bootchain}
RZB_SHARE_DIR=${RZB_SHARE_DIR:-/usr/share/rzv2l-bootchain}
RZB_BOOT_DIR=${RZB_BOOT_DIR:-/boot}
RZB_DT=${RZB_DT:-/proc/device-tree}
RZB_SYSFS=${RZB_SYSFS:-/sys}
RZB_BOOT_ID_FILE=${RZB_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
# On-chip RAM the ROM loads BL2 into: 0x12000-0x2EFFF.
RZB_BL2_MAX=$((0x1D000))

RZB_TAG=${RZB_TAG:-rzv2l-bootchain}
rzb_log() { printf '[%s] %s\n' "$RZB_TAG" "$*" >&2; }
rzb_die() { printf '[%s][ERROR] %s\n' "$RZB_TAG" "$*" >&2; exit 1; }

# Strict decimal/0x-hex integer $1 (label $2) -> decimal; refuses anything else.
rzb_int() {
    case "$1" in
        0x[0-9a-fA-F]*) [ -z "$(printf '%s' "${1#0x}" | tr -d '0-9a-fA-F')" ] && { echo $(( $1 )); return 0; } ;;
        [0-9]*) [ -z "$(printf '%s' "$1" | tr -d '0-9')" ] && { echo $(( 10#$1 )); return 0; } ;;
    esac
    rzb_die "bundle meta ${2}='${1}' is not an integer; refusing"
}

rzb_boot_id() { tr -d '\n' < "$RZB_BOOT_ID_FILE"; }

# key=value file $1, key $2 -> value (first match, no evaluation).
rzb_kv() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"; }

# --- EXT_CSD -------------------------------------------------------------
# Prints "<PARTITION_CONFIG> <BOOT_BUS_CONDITIONS>" as decimal.
rzb_extcsd() {
    local out pc bb
    out="$(mmc extcsd read "$RZB_MMC_DEV" 2>/dev/null)" || rzb_die "cannot read EXT_CSD of ${RZB_MMC_DEV}"
    pc="$(printf '%s\n' "$out" | sed -n 's/.*\[PARTITION_CONFIG: \(0x[0-9a-fA-F]*\)\].*/\1/p' | head -1)"
    bb="$(printf '%s\n' "$out" | sed -n 's/.*\[BOOT_BUS_CONDITIONS: \(0x[0-9a-fA-F]*\)\].*/\1/p' | head -1)"
    [ -n "$pc" ] && [ -n "$bb" ] || rzb_die "PARTITION_CONFIG/BOOT_BUS_CONDITIONS not found in EXT_CSD of ${RZB_MMC_DEV}"
    echo "$(( pc )) $(( bb ))"
}

# Index (0 = boot0, 1 = boot1) of the boot partition EXT_CSD[179] enables.
# RAUC treats "not enabled" as boot1 active and user-area as an error; both are
# refused here because the ROM would not boot what gets written.
rzb_active_index() {
    local v pc bb en
    v="$(rzb_extcsd)" || exit 1
    IFS=" " read -r pc bb <<< "$v"
    en=$(( (pc >> 3) & 7 ))
    case "$en" in
        1) echo 0 ;;
        2) echo 1 ;;
        *) rzb_die "EXT_CSD PARTITION_CONFIG=$(printf '%#04x' "$pc") enables boot partition field ${en}, not boot0/boot1 — provision the eMMC boot partition first; refusing" ;;
    esac
}

# Board state the bootloader slot needs: booted from eMMC, a real eMMC on
# RZB_MMC_DEV, BOOT_ACK off and an 8-bit boot bus (the ROM needs both), boot0
# or boot1 enabled, both boot partitions present. Prints the active index.
rzb_check_board() {
    local src type v pc bb idx
    src="$(tr -d '\0' < "${RZB_DT}/chosen/edge,boot-source" 2>/dev/null || true)"
    [ "$src" = emmc ] || rzb_die "board booted from '${src:-unknown}', not emmc — the bootloader slot updates the eMMC boot partitions only; refusing"
    type="$(cat "${RZB_SYSFS}/block/$(basename "$RZB_MMC_DEV")/device/type" 2>/dev/null || true)"
    [ "$type" = MMC ] || rzb_die "${RZB_MMC_DEV} is '${type:-unknown}', not an eMMC; refusing"
    [ -e "${RZB_MMC_DEV}boot0" ] && [ -e "${RZB_MMC_DEV}boot1" ] || rzb_die "${RZB_MMC_DEV}boot0/boot1 missing; refusing"
    v="$(rzb_extcsd)" || exit 1
    IFS=" " read -r pc bb <<< "$v"
    [ $(( pc & 0x40 )) -eq 0 ] || rzb_die "EXT_CSD PARTITION_CONFIG=$(printf '%#04x' "$pc") has BOOT_ACK set; the ROM needs it off; refusing"
    [ $(( bb & 3 )) -eq 2 ] || rzb_die "EXT_CSD BOOT_BUS_CONDITIONS=$(printf '%#04x' "$bb") is not the 8-bit boot bus the ROM needs; refusing"
    idx="$(rzb_active_index)" || exit 1
    echo "$idx"
}

# Size in bytes of boot partition index $1.
rzb_bootpart_size() {
    local n; n="$(basename "$RZB_MMC_DEV")boot$1"
    echo $(( $(cat "${RZB_SYSFS}/block/${n}/size") * 512 ))
}

# --- variant ---------------------------------------------------------------
# The SMARC EVK with the RAA215300 PMIC needs the _pmic BL2. Same detection as
# rzv2l-bootloader-update.
rzb_detected_variant() {
    if grep -qs 'renesas,raa215300' "${RZB_DT}"/soc/*/pmic@*/compatible \
       || grep -qsx 'raa215300' "${RZB_SYSFS}"/bus/i2c/devices/*/name; then
        echo pmic
    else
        echo non-pmic
    fi
}

# --- image layout ----------------------------------------------------------
rzb_hex() { od -An -tx1 -v -j"$2" -N"$3" "$1" | tr -d ' \n'; }

# rzb_check_image <file> <bl2-size> <bl2-sha256> <fip-size> <fip-sha256>
# Checks the composed image against the layout and the per-part hashes the
# bundle declares. The same function runs on the bundle file (pre-install) and
# on the written partition (post-install read-back).
rzb_check_image() {
    local f="$1" bl2_size="$2" bl2_sha="$3" fip_size="$4" fip_sha="$5" size word body h
    case "${bl2_size}" in ''|*[!0-9]*) rzb_die "bl2-size '${bl2_size}' not numeric; refusing" ;; esac
    case "${fip_size}" in ''|*[!0-9]*) rzb_die "fip-size '${fip_size}' not numeric; refusing" ;; esac
    size=$(( RZB_FIP_OFFSET + fip_size ))
    [ "$(stat -Lc%s "$f" 2>/dev/null || echo 0)" -ge "$size" ] || rzb_die "image $f is shorter than fip-offset + fip-size (${size} B); refusing"
    [ $(( RZB_BL2_OFFSET + bl2_size )) -le "$RZB_FIP_OFFSET" ] || rzb_die "BL2 (${bl2_size} B @ $(printf '%#x' "$RZB_BL2_OFFSET")) overlaps the FIP @ $(printf '%#x' "$RZB_FIP_OFFSET"); refusing"
    [ -z "$(rzb_hex "$f" 0 "$RZB_BL2_OFFSET" | tr -d 0)" ] || rzb_die "image bytes below the BL2 offset are not zero; refusing"
    [ "$(rzb_hex "$f" $(( RZB_BL2_OFFSET + 0x1FE )) 2)" = 55aa ] || rzb_die "no BL2 boot-parameter signature (AA55) at $(printf '%#x' $(( RZB_BL2_OFFSET + 0x1FE ))); refusing"
    # One 512-byte boot-parameter block, then the body; the size word is the
    # body length rounded up to 4 (bptool).
    body=$(( bl2_size - 0x200 ))
    word="$(od -An -tu4 --endian=little -j"$RZB_BL2_OFFSET" -N4 "$f" | tr -d ' ')"
    [ "$body" -gt 0 ] && [ -n "$word" ] && [ "$word" -eq $(( (body + 3) & ~3 )) ] \
        || rzb_die "BL2 size word ${word:-?} does not match the ${body}-byte body after the boot parameters; refusing"
    [ "$word" -le "$RZB_BL2_MAX" ] || rzb_die "BL2 body ${word} B exceeds the ROM load window ${RZB_BL2_MAX} B; refusing"
    [ "$(rzb_hex "$f" "$RZB_FIP_OFFSET" 4)" = 010064aa ] || rzb_die "no FIP ToC (0xAA640001) at $(printf '%#x' "$RZB_FIP_OFFSET"); refusing"
    h="$(dd if="$f" iflag=skip_bytes,count_bytes skip="$RZB_BL2_OFFSET" count="$bl2_size" status=none | sha256sum | awk '{print $1}')"
    [ "$h" = "$bl2_sha" ] || rzb_die "BL2 region hash ${h:0:16}… != bundle bl2-sha256 ${bl2_sha:0:16}…; refusing"
    h="$(dd if="$f" iflag=skip_bytes,count_bytes skip="$RZB_FIP_OFFSET" count="$fip_size" status=none | sha256sum | awk '{print $1}')"
    [ "$h" = "$fip_sha" ] || rzb_die "FIP region hash ${h:0:16}… != bundle fip-sha256 ${fip_sha:0:16}…; refusing"
}

# TF-A pin $1 with FIP offset $2 must be a known pair (contract K0).
rzb_check_layout_pin() {
    local pin="$1" off="$2" e
    case "$off" in ''|*[!0-9]*) rzb_die "fip-offset '${off}' not numeric; refusing" ;; esac
    for e in ${RZB_TFA_FIP_LAYOUT// /$'\n'}; do
        if [ "${e%%:*}" = "$pin" ]; then
            [ $(( ${e#*:} )) -eq $(( off )) ] && [ $(( off )) -eq "$RZB_FIP_OFFSET" ] && return 0
            rzb_die "TF-A pin ${pin} reads the FIP at ${e#*:}, bundle declares ${off}, this system expects $(printf '%#x' "$RZB_FIP_OFFSET"); refusing"
        fi
    done
    rzb_die "TF-A pin '${pin:-}' is not in the known layouts (${RZB_TFA_FIP_LAYOUT}); refusing"
}

# --- FIT anchor --------------------------------------------------------------
# U-Boot verifies the slot FITs against the keys in its control DTB inside the
# FIP. The candidate must hold, as required="conf", the key (RSA modulus +
# exponent) behind each slot FIT, identified through the current anchor. Unlike
# rzv2l-bootloader-update, which must also restore over a torn FIP, there is no
# name-only fallback: a same-named key is not the same key, so a current anchor
# that is unreadable or lacks a slot's signer is a refusal.

# First DTB carrying /signature/key-* in file $1 -> $2. LC_ALL=C: in a UTF-8
# locale PCRE reads \xd0 as U+00D0, not the byte, and finds no FDT.
rzb_fip_anchor() {
    local src="$1" out="$2" off size
    for off in $(LC_ALL=C grep -obUaP '\xd0\x0d\xfe\xed' "$src" 2>/dev/null | cut -d: -f1); do
        size=$(od -An -tu4 --endian=big -j$((off + 4)) -N4 "$src" | tr -d ' ')
        [ -n "$size" ] && [ "$size" -gt 64 ] && [ "$size" -lt 1048576 ] || continue
        dd if="$src" of="$out" iflag=skip_bytes,count_bytes skip="$off" count="$size" status=none
        fdtget -l "$out" /signature 2>/dev/null | grep -q '^key-' && return 0
    done
    rm -f "$out"; return 1
}

rzb_key_fp() {
    fdtget -t x "$1" "/signature/$2" rsa,modulus >/dev/null 2>&1 || return 0
    { fdtget -t x "$1" "/signature/$2" rsa,modulus; fdtget -t x "$1" "/signature/$2" rsa,exponent; } \
        | sha256sum | awk '{print $1}'
}

rzb_required_fps() {
    local k
    for k in $(fdtget -l "$1" /signature 2>/dev/null); do
        case "$k" in key-*) [ "$(fdtget "$1" "/signature/$k" required 2>/dev/null)" = conf ] && rzb_key_fp "$1" "$k" ;; esac
    done
    return 0
}

rzb_fit_signer() {
    local s
    for s in $(fdtget -l "$1" "/configurations/$2" 2>/dev/null); do
        case "$s" in signature*) fdtget "$1" "/configurations/$2/$s" key-name-hint 2>/dev/null; return 0 ;; esac
    done
    return 0
}

# rzb_check_anchor <candidate-dtb> <current-dtb>
rzb_check_anchor() {
    local cand="$1" cur="$2" trusted slot fit hint fp
    [ -s "$cur" ] || rzb_die "anchor guard: no current anchor to identify the slot FIT keys; refusing"
    trusted="$(rzb_required_fps "$cand")"
    [ -n "$trusted" ] || rzb_die "anchor guard: candidate U-Boot DTB has no required=\"conf\" FIT key; refusing"
    for slot in A B; do
        fit="${RZB_BOOT_DIR}/fitImage-${slot}"
        [ -f "$fit" ] || { rzb_log "anchor guard: no ${fit}; slot ${slot} not checked"; continue; }
        hint="$(rzb_fit_signer "$fit" "conf-${slot}")"
        [ -n "$hint" ] || rzb_die "anchor guard: ${fit} conf-${slot} carries no signature; refusing"
        fp="$(rzb_key_fp "$cur" "key-${hint}")"
        [ -n "$fp" ] || rzb_die "anchor guard: slot ${slot} signer '${hint}' is not a key of the current anchor, so the candidate's key of that name cannot be shown to be the same key; refusing"
        printf '%s\n' "$trusted" | grep -qx "$fp" \
            || rzb_die "anchor guard: candidate does not trust key '${hint}' (${fp:0:16}…) that signed slot ${slot}; refusing"
        rzb_log "anchor guard: slot ${slot} signer '${hint}' (${fp:0:16}…) trusted by the candidate"
    done
}

# Anchor of the FIP in the active boot partition (index $1) -> $2.
rzb_current_anchor() {
    local idx="$1" out="$2" region rc=0
    region="$(mktemp "${RZB_RUN_DIR}/cur.XXXXXX")"
    dd if="${RZB_MMC_DEV}boot${idx}" of="$region" iflag=skip_bytes skip="$RZB_FIP_OFFSET" status=none 2>/dev/null || true
    rzb_fip_anchor "$region" "$out" || rc=1
    rm -f "$region"
    return "$rc"
}
