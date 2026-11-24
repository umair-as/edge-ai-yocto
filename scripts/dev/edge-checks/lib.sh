# shellcheck shell=bash
# On-device check runner shared by every suite under scripts/dev/edge-checks/.
# build.sh concatenates this file, the suite header and the suite's modules
# into one self-contained script, so `ssh <board> 'bash -s' < script` works.
#
# Module contract (one file per product area, NN-<area>.sh):
#   edge_check <id> <tier> <title> <function>
#     id     stable dotted name, e.g. storage.binds; never reused for another check
#     tier   core           must hold on every image; never skipped
#            cap:<name>     runs only when the image declares <name>
#     title  section header printed before the function runs
#   edge_cap_<name>() probes a capability (non-alphanumerics in <name> become _).
#     Returns 0 when present; otherwise prints the skip reason and returns 1.
#     Every cap: tier needs one (the selftest enforces it).
#   ${EDGE_CHECKS_DIR}/capabilities, one name per line, declares further
#   capabilities; it adds to the probes and never hides a probed one.
#
# Runtime environment:
#   EDGE_CHECK_IDS="glob ..."   run only matching check ids (e.g. "accel.* net.*");
#                               a selection matching nothing exits 2
#   EDGE_CHECK_RESULTS=<file>   also append "<id>\t<STATUS>\t<message>" per verdict
#   EDGE_CHECKS_SOURCE_ONLY=1   define everything, run nothing (host tests)
#   --list                      print "<id> <tier> <title>" and exit

set -u
# A serial login gives non-root users no sbin (oe-core /etc/profile); sshd does.
PATH=$PATH:/usr/sbin:/sbin
# pipefail makes `producer | grep -q` report failure whenever grep exits on
# the first match before the producer is done writing (SIGPIPE); greps fed
# by a long-running producer therefore read to EOF (`grep ... >/dev/null`).
set -o pipefail

EDGE_BUILDINFO=${EDGE_BUILDINFO:-/etc/buildinfo}
EDGE_RAUC_CONF=${EDGE_RAUC_CONF:-/etc/rauc/system.conf}
EDGE_CHECKS_DIR=${EDGE_CHECKS_DIR:-/usr/share/edge-checks}

# ---------------- output ----------------

if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''; C_RESET=''
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
EDGE_CHECK_ID=""

edge_record() {
    [ -n "${EDGE_CHECK_RESULTS:-}" ] || return 0
    printf '%s\t%s\t%s\n' "${EDGE_CHECK_ID:-?}" "$1" "$2" >> "${EDGE_CHECK_RESULTS}"
}
section() { printf "\n${C_BLUE}== %s ==${C_RESET}\n" "$*"; }
pass()    { printf "  ${C_GREEN}PASS${C_RESET}  %s\n" "$*"; PASS_COUNT=$((PASS_COUNT+1)); edge_record PASS "$*"; }
fail()    { printf "  ${C_RED}FAIL${C_RESET}  %s\n" "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); edge_record FAIL "$*"; }
warn()    { printf "  ${C_YELLOW}WARN${C_RESET}  %s\n" "$*"; WARN_COUNT=$((WARN_COUNT+1)); edge_record WARN "$*"; }
info()    { printf "  ${C_DIM}%s${C_RESET}\n" "$*"; }

# ---------------- parsers (pure; covered by scripts/ci/edge-checks-selftest.sh) ----------------

# buildinfo_get <key> [file]: value of KEY= in /etc/buildinfo, empty if absent.
buildinfo_get() {
    awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "${2:-${EDGE_BUILDINFO}}" 2>/dev/null
}

# rauc_conf_get <file> <section> <key>...: first value in [section] whose key
# is any of the given keys, in file order.
rauc_conf_get() {
    local file=$1 sect=$2; shift 2
    awk -v s="[${sect}]" -v keys=" $* " '
        /^[ \t]*\[/ { cur=$0; gsub(/[ \t]/, "", cur); next }
        cur == s && /=/ {
            k=$0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
            if (index(keys, " " k " ")) { v=$0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]*$/, "", v); print v; exit }
        }' "${file}" 2>/dev/null
}

# rauc_slot_device <file> <bootname>: device= of the slot with that bootname.
rauc_slot_device() {
    [ -n "$2" ] || return 0
    awk -v want="$2" '
        function flush() { if (inslot && bn == want && dev != "") { print dev; found=1; exit } }
        /^[ \t]*\[/ { flush(); inslot = ($0 ~ /^[ \t]*\[slot\./); bn=""; dev=""; next }
        inslot && /^[ \t]*bootname[ \t]*=/ { bn=$0; sub(/^[^=]*=[ \t]*/, "", bn); sub(/[ \t\r]*$/, "", bn) }
        inslot && /^[ \t]*device[ \t]*=/   { dev=$0; sub(/^[^=]*=[ \t]*/, "", dev); sub(/[ \t\r]*$/, "", dev) }
        END { if (!found) flush() }' "$1" 2>/dev/null
}

# unit_prop <`systemctl show -p ...` output> <Name>: one property's value.
unit_prop() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# unit_state_class <`systemctl show -p ActiveState -p Result -p ConditionResult` output>:
# unreadable | condition-unmet | completed | running | failed, for a oneshot-style
# workload unit whose own result decides (journal text alone cannot).
unit_state_class() {
    if [ -z "$1" ]; then echo unreadable; return; fi
    if [ "$(unit_prop "$1" ConditionResult)" != yes ]; then echo condition-unmet; return; fi
    case "$(unit_prop "$1" ActiveState)/$(unit_prop "$1" Result)" in
        inactive/success) echo completed ;;
        activating/* | active/*) echo running ;;
        *) echo failed ;;
    esac
}

# netlink_field <iface> <column>: column of `networkctl --no-legend list`
# (IDX LINK TYPE OPERATIONAL SETUP) for one link, read from stdin.
netlink_field() { awk -v i="$1" -v c="$2" '$2==i{print $c}'; }

# kconfig_mismatches <list> <config>: one "SYMBOL want got" line per entry of
# an expectation list (kernel fragment syntax: CONFIG_X=y|m|<value>, or
# "# CONFIG_X is not set") that the kernel config does not satisfy. Absent and
# "is not set" both read as n.
kconfig_mismatches() {
    awk '
        FNR == NR {
            sub(/\r$/, "")
            if ($0 ~ /^CONFIG_[A-Za-z0-9_]+=/) { k=$0; sub(/=.*/, "", k); v=$0; sub(/^[^=]*=/, "", v); have[k]=v }
            next
        }
        { sub(/\r$/, ""); sub(/[ \t]+$/, ""); s=""; w="" }
        /^# CONFIG_[A-Za-z0-9_]+ is not set$/ { s=$2; w="n" }
        /^CONFIG_[A-Za-z0-9_]+=/ { s=$0; sub(/=.*/, "", s); w=$0; sub(/^[^=]*=/, "", w) }
        s != "" { g = (s in have) ? have[s] : "n"; if (g != w) print s, w, g }
    ' "$2" "$1"
}

# kconfig_count <list>: number of expectations in a list.
kconfig_count() { [ -r "$1" ] || { echo 0; return; }; grep -cE '^(CONFIG_[A-Za-z0-9_]+=|# CONFIG_[A-Za-z0-9_]+ is not set)' "$1" 2>/dev/null || true; }

# ---------------- image facts (read once; modules use these, not literals) ----------------

edge_accel_probe() {
    local accel=none
    [ -n "$(find "/lib/modules/$(uname -r)" -name 'drpai.ko*' 2>/dev/null | head -1)" ] && accel=drpai-v2l
    [ -f /etc/udev/rules.d/71-edge-dxm1.rules ] && accel=dxm1
    [ -e /usr/lib/libQnnHtp.so ] && accel=qnn-htp-v75
    echo "${accel}"
}

# Facts are read here and used by modules; not every suite uses every one.
# shellcheck disable=SC2034
edge_load_facts() {
    EDGE_MACHINE=$(buildinfo_get MACHINE)
    EDGE_BUILD_ID=$(buildinfo_get EDGE_BUILD_ID)
    EDGE_IMAGE=$(buildinfo_get IMAGE_BASENAME)
    EDGE_ACCEL_COMPOSED=$(buildinfo_get EDGE_ACCEL)
    EDGE_ALLOW_NO_ACCEL=$(buildinfo_get EDGE_ALLOW_NO_ACCEL)
    # The composed accelerator decides; images that predate the record, or
    # record none, fall back to the installed stack.
    case "${EDGE_ACCEL_COMPOSED}" in
        "" | none) EDGE_ACCEL=$(edge_accel_probe) ;;
        *)         EDGE_ACCEL=${EDGE_ACCEL_COMPOSED} ;;
    esac
    EDGE_CMDLINE=$(cat /proc/cmdline 2>/dev/null)
    EDGE_SLOT=$(printf '%s' "${EDGE_CMDLINE}" | sed -n 's/.*rauc\.slot=\([AB]\).*/\1/p')
    EDGE_BOOT_CHAIN=uboot
    [ "$(rauc_conf_get "${EDGE_RAUC_CONF}" system bootloader)" = custom ] && EDGE_BOOT_CHAIN=sdboot
    # The A/B pair is the product contract, not read from system.conf: a slot
    # missing there must fail its checks, not drop them.
    EDGE_SLOTS="A B"
    ECTR_UID=$(id -u edge-ctr 2>/dev/null || true)
    ECTR_HOME=$(awk -F: '$1=="edge-ctr"{print $6}' /etc/passwd 2>/dev/null)
    # Uplink = the shipped networkd unit that is not Unmanaged; unmanaged = the
    # rest. edge-network-units templates both from the board include.
    EDGE_UPLINK=""; EDGE_UNMANAGED=""
    local u n
    for u in /etc/systemd/network/10-*.network; do
        [ -f "${u}" ] || continue
        n=$(basename "${u}" .network); n=${n#10-}
        if grep -qE '^\s*Unmanaged\s*=\s*yes' "${u}"; then EDGE_UNMANAGED="${EDGE_UNMANAGED} ${n}"; else EDGE_UPLINK="${n}"; fi
    done
}

# ---------------- runner ----------------

EDGE_CHECK_REG=()
EDGE_SKIPPED=()

edge_check() { EDGE_CHECK_REG+=("$1|$2|$3|$4"); }

edge_selected() {
    local g
    [ -n "${EDGE_CHECK_IDS:-}" ] || return 0
    # The patterns match ids, never file names in the working directory.
    set -f
    for g in ${EDGE_CHECK_IDS}; do
        # shellcheck disable=SC2254
        case "$1" in ${g}) set +f; return 0 ;; esac
    done
    set +f
    return 1
}

# edge_cap <name>: 0 when the image declares capability <name>; else prints why not.
edge_cap() {
    local fn
    if [ -r "${EDGE_CHECKS_DIR}/capabilities" ] && grep -qxF -- "$1" "${EDGE_CHECKS_DIR}/capabilities"; then
        return 0
    fi
    fn="edge_cap_${1//[^A-Za-z0-9_]/_}"
    if ! declare -F "${fn}" >/dev/null; then
        echo "no probe for capability '$1'"
        return 1
    fi
    "${fn}"
}

edge_main() {
    local e id tier title fn reason ran=0
    if [ "${1:-}" = --list ]; then
        for e in "${EDGE_CHECK_REG[@]}"; do
            IFS='|' read -r id tier title fn <<< "${e}"
            printf '%-30s %-22s %s\n' "${id}" "${tier}" "${title}"
        done
        return 0
    fi
    edge_load_facts
    if declare -F edge_suite_preamble >/dev/null; then edge_suite_preamble; fi
    for e in "${EDGE_CHECK_REG[@]}"; do
        IFS='|' read -r id tier title fn <<< "${e}"
        edge_selected "${id}" || continue
        ran=$((ran + 1))
        EDGE_CHECK_ID=${id}
        if [ "${tier#cap:}" != "${tier}" ] && ! reason=$(edge_cap "${tier#cap:}"); then
            EDGE_SKIPPED+=("${id}: ${reason:-capability ${tier#cap:} not declared}")
            edge_record SKIP "${reason}"
            continue
        fi
        section "${title}"
        "${fn}"
    done
    EDGE_CHECK_ID=""
    if [ "${ran}" -eq 0 ]; then
        echo "no check id matches EDGE_CHECK_IDS='${EDGE_CHECK_IDS:-}' (--list shows them)" >&2
        return 2
    fi
    if [ ${#EDGE_SKIPPED[@]} -gt 0 ]; then
        section "Skipped (capability not declared by this image)"
        for e in "${EDGE_SKIPPED[@]}"; do info "${e}"; done
    fi

    printf "\n${C_BLUE}==================== summary ====================${C_RESET}\n"
    printf "  ${C_GREEN}PASS:${C_RESET} %d   ${C_YELLOW}WARN:${C_RESET} %d   ${C_RED}FAIL:${C_RESET} %d\n" \
        "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
    [ "${FAIL_COUNT}" -eq 0 ]
}

# ---------------- helpers shared by modules ----------------

# accel_is <name>: capability probe for accel:<name> modules.
accel_is() {
    [ "${EDGE_ACCEL}" = "$1" ] && return 0
    echo "accelerator is ${EDGE_ACCEL}"
    return 1
}

# accel_has_module: EDGE_ACCEL names an accelerator a module checks.
accel_has_module() {
    [ "${EDGE_ACCEL}" != none ] && declare -F "edge_cap_accel_${EDGE_ACCEL//[^A-Za-z0-9_]/_}" >/dev/null
}

# devnode_mode <path> <ls -l prefix> <group> <octal> <missing message>
devnode_mode() {
    local l
    if [ -e "$1" ]; then
        l=$(ls -l "$1")
        if printf '%s' "${l}" | grep -E "^$2.* root $3 " >/dev/null; then
            pass "$1 root:$3 $4"
        else
            fail "$1 not root:$3 $4: ${l}"
        fi
    else
        fail "$5"
    fi
}

# ectr_in_group <group>: edge-ctr carries the accelerator group (keep-groups).
ectr_in_group() {
    id -nG edge-ctr 2>/dev/null | tr ' ' '\n' | grep -x "$1" >/dev/null \
        && pass "edge-ctr is in $1 (rootless passthrough via keep-groups)" \
        || fail "edge-ctr is not in the $1 group"
}

# podman_wait_dropin: the 90 s podman-user-wait-network-online timeout
# (podman #22197) is neutralized by a no-op ExecStart drop-in.
podman_wait_dropin() {
    if [ -f /etc/systemd/user/podman-user-wait-network-online.service.d/10-edge-noop.conf ]; then
        pass "podman-user-wait no-op drop-in present (no 90s inference delay)"
    else
        warn "podman-user-wait no-op drop-in missing — first inference likely delayed ~90s at boot"
    fi
}

# ectr_unit_show <unit> <props...>: systemctl show from edge-ctr's user manager.
ectr_unit_show() {
    local unit=$1 p args=(); shift
    for p in "$@"; do args+=(-p "${p}"); done
    sudo -n -u edge-ctr env XDG_RUNTIME_DIR="/run/user/${ECTR_UID}" systemctl --user show "${unit}" "${args[@]}" 2>/dev/null
}
