#!/usr/bin/env bash
# Host-only selftest for the on-device check suites (scripts/dev/edge-checks/):
# generated scripts are current, the parsers and the runner behave on
# fixtures, and the three invocation forms (file, `bash -s` on stdin, sourced)
# work. No root, no board.
#
#   scripts/ci/edge-checks-selftest.sh
# Settings such as EDGE_KCONFIG are read by the sourced suite functions.
# shellcheck disable=SC2034
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EC=$ROOT/scripts/dev/edge-checks
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
# Blocks run in subshells (lib.sh sets -u/pipefail and PATH for itself);
# each hands its counts back through $T/counts.
block_end() { echo "$pass $fail" >> "$T/counts"; exit 0; }
# eq <label> <got> <want>
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', want '$3'"; fi; }

# --- generated scripts are current -------------------------------------------

if "$EC/build.sh" --check; then ok; else bad "generated scripts stale"; fi

# --- parsers -------------------------------------------------------------------

(
    pass=0 fail=0
    . "$EC/lib.sh"
    cat > "$T/buildinfo" <<'EOF'
MACHINE=smarc-rzv2l
EDGE_ACCEL=drpai-v2l
IMAGE_NAME=edge-image-dev-smarc-rzv2l=x
EOF
    eq "buildinfo_get" "$(buildinfo_get MACHINE "$T/buildinfo")" smarc-rzv2l
    eq "buildinfo_get keeps '=' in value" "$(buildinfo_get IMAGE_NAME "$T/buildinfo")" "edge-image-dev-smarc-rzv2l=x"
    eq "buildinfo_get absent key" "$(buildinfo_get EDGE_ALLOW_NO_ACCEL "$T/buildinfo")" ""
    eq "buildinfo_get prefix is not a key" "$(buildinfo_get EDGE "$T/buildinfo")" ""

    cat > "$T/system.conf" <<'EOF'
[system]
compatible=edge-board
bootloader = custom
data-directory=/data/rauc

[keyring]
directory=/etc/rauc/certs
path=/etc/rauc/ca.cert.pem

[slot.rootfs.0]
device=/dev/disk/by-rauc-slot/rootfsA
type=raw
bootname=A

[slot.efi.0]
device=/dev/disk/by-partlabel/esp

[slot.rootfs.1]
bootname=B
device=/dev/disk/by-rauc-slot/rootfsB
EOF
    eq "rauc_conf_get spaces around =" "$(rauc_conf_get "$T/system.conf" system bootloader)" custom
    eq "rauc_conf_get first of keys in file order" "$(rauc_conf_get "$T/system.conf" keyring path directory)" /etc/rauc/certs
    eq "rauc_conf_get section-scoped" "$(rauc_conf_get "$T/system.conf" keyring compatible)" ""
    eq "rauc_conf_get missing file" "$(rauc_conf_get "$T/nope" system bootloader)" ""
    eq "rauc_slot_device A" "$(rauc_slot_device "$T/system.conf" A)" /dev/disk/by-rauc-slot/rootfsA
    eq "rauc_slot_device bootname before device" "$(rauc_slot_device "$T/system.conf" B)" /dev/disk/by-rauc-slot/rootfsB
    eq "rauc_slot_device unknown" "$(rauc_slot_device "$T/system.conf" C)" ""
    eq "rauc_slot_device empty bootname" "$(rauc_slot_device "$T/system.conf" "")" ""

    show=$'ActiveState=inactive\nResult=success\nExecMainStatus=0\nConditionResult=yes\nNRestarts=2'
    eq "unit_prop" "$(unit_prop "$show" NRestarts)" 2
    eq "unit_state unreadable" "$(unit_state_class "")" unreadable
    eq "unit_state completed" "$(unit_state_class "$show")" completed
    eq "unit_state condition" "$(unit_state_class "${show/ConditionResult=yes/ConditionResult=no}")" condition-unmet
    eq "unit_state running" "$(unit_state_class "${show/ActiveState=inactive/ActiveState=activating}")" running
    eq "unit_state active" "$(unit_state_class "${show/ActiveState=inactive/ActiveState=active}")" running
    eq "unit_state failed" "$(unit_state_class "${show/ActiveState=inactive/ActiveState=failed}")" failed
    eq "unit_state inactive+exit-code" "$(unit_state_class "${show/Result=success/Result=exit-code}")" failed

    links=$'  1 lo   loopback carrier  unmanaged\n  2 eth0 ether    off      unmanaged\n  3 eth1 ether    routable configured'
    eq "netlink operational" "$(printf '%s\n' "$links" | netlink_field eth1 4)" routable
    eq "netlink setup" "$(printf '%s\n' "$links" | netlink_field eth0 5)" unmanaged
    eq "netlink absent" "$(printf '%s\n' "$links" | netlink_field end0 4)" ""

    printf 'CONFIG_NF_TABLES=y\nCONFIG_NFT_NAT=m\n# CONFIG_IP_NF_IPTABLES is not set\nCONFIG_IPVLAN=y\nCONFIG_LOCALVERSION="-edge"\r\n' > "$T/config"
    cat > "$T/k.list" <<'EOF'
# nftables-only kernel
CONFIG_NF_TABLES=y
CONFIG_NFT_NAT=y
# CONFIG_IP_NF_IPTABLES is not set
# CONFIG_NETFILTER_XTABLES is not set
# CONFIG_IPVLAN is not set
CONFIG_IP_SET=n
CONFIG_LOCALVERSION="-edge"
EOF
    eq "kconfig_mismatches" "$(kconfig_mismatches "$T/k.list" "$T/config" | tr '\n' ';')" \
        "CONFIG_NFT_NAT y m;CONFIG_IPVLAN n y;"
    eq "kconfig_count" "$(kconfig_count "$T/k.list")" 7
    eq "kconfig_count no list" "$(kconfig_count "$T/none.list")" 0
    block_end
)

# --- check_bind against a stub findmnt -----------------------------------------

mkdir -p "$T/bin"
cat > "$T/bin/findmnt" <<'EOF'
#!/bin/sh
# --target <path> -no <COL>; table in $FINDMNT_TABLE: "<path> <SOURCE> <FSROOT>"
[ "$1" = --target ] || exit 1
awk -v p="$2" -v c="$4" '$1==p { print (c=="SOURCE" ? $2 : $3); f=1 } END { exit !f }' "$FINDMNT_TABLE"
EOF
chmod +x "$T/bin/findmnt"
cat > "$T/mounts" <<'EOF'
/var/log /dev/mmcblk0p5[/log] /log
/home /dev/mmcblk0p5 /
/var/lib/x /dev/sda3[/x] /x
/var/lib/x overlay /
EOF
(
    pass=0 fail=0
    . "$EC/lib.sh"
    . "$EC/smoke/31-binds.sh"
    PATH=$T/bin:$PATH FINDMNT_TABLE=$T/mounts
    export FINDMNT_TABLE
    eq "check_bind match" "$(check_bind /var/log /data/log)" "  PASS  /var/log <- /dev/mmcblk0p5[/log] (fsroot=/log)"
    eq "check_bind wrong fsroot" "$(check_bind /home /data/home)" \
        "  FAIL  /home: fsroot='/' source='/dev/mmcblk0p5' (wanted /data/home / fsroot /home)"
    eq "check_bind nothing mounted" "$(check_bind /var/lib/containers /data/containers)" "  FAIL  /var/lib/containers: nothing mounted"
    eq "check_bind first line of stacked mounts" "$(check_bind /var/lib/x /data/x)" "  PASS  /var/lib/x <- /dev/sda3[/x] (fsroot=/x)"
    block_end
)

# --- kernel config expectation lists -------------------------------------------

mkdir -p "$T/checks"
(
    pass=0 fail=0
    . "$EC/lib.sh"
    . "$EC/smoke/71-kernel-config.sh"
    EDGE_CHECKS_DIR=$T/checks EDGE_KCONFIG=$T/config
    out=$(chk_kernel_config)
    eq "kconfig no list" "$out" "  WARN  no kernel config expectation lists ($T/checks/kernel-config-*.list); check skipped"
    printf 'CONFIG_NF_TABLES=y\n# CONFIG_IP_NF_IPTABLES is not set\n' > "$T/checks/kernel-config-nft.list"
    eq "kconfig holds" "$(chk_kernel_config)" "  PASS  kernel-config-nft.list: 2 kernel config expectations hold"
    printf 'CONFIG_NFT_NAT=y\n# CONFIG_IPVLAN is not set\n' > "$T/checks/kernel-config-more.list"
    out=$(chk_kernel_config)
    eq "kconfig mismatch lines" "$out" "  FAIL  kernel-config-more.list: CONFIG_NFT_NAT is m, expected y
  FAIL  kernel-config-more.list: CONFIG_IPVLAN is y, expected not set
  PASS  kernel-config-nft.list: 2 kernel config expectations hold"
    EDGE_KCONFIG=$T/missing
    eq "kconfig unreadable" "$(chk_kernel_config | sed 's/config-[^)]*)/config-R)/')" \
        "  WARN  kernel config not readable (/proc/config.gz, /boot/config-R); 2 list(s) not checked"
    block_end
)

# --- runner: capabilities, selection, results, skip report --------------------

cat > "$T/suite.sh" <<'EOF'
edge_check t.core core "Core" t_core
edge_check t.on cap:feature-on "On" t_on
edge_check t.off cap:feature-off "Off" t_off
edge_check t.noprobe cap:unprobed "No probe" t_on
edge_cap_feature_on() { return 0; }
edge_cap_feature_off() { echo "feature absent"; return 1; }
edge_load_facts() { :; }
t_core() { pass "core ok"; }
t_on() { warn "on ran"; }
t_off() { fail "off ran"; }
EOF
(
    pass=0 fail=0
    . "$EC/lib.sh"
    . "$T/suite.sh"
    EDGE_CHECKS_DIR=$T/nocaps EDGE_CHECK_RESULTS=$T/results
    out=$(edge_main); rc=$?
    eq "runner exit" "$rc" 0
    eq "runner output" "$out" "
== Core ==
  PASS  core ok

== On ==
  WARN  on ran

== Skipped (capability not declared by this image) ==
  t.off: feature absent
  t.noprobe: no probe for capability 'unprobed'

==================== summary ====================
  PASS: 1   WARN: 1   FAIL: 0"
    eq "results file" "$(cat "$T/results")" "t.core	PASS	core ok
t.on	WARN	on ran
t.off	SKIP	feature absent
t.noprobe	SKIP	no probe for capability 'unprobed'"
    EDGE_CHECK_RESULTS=""
    eq "selection" "$(EDGE_CHECK_IDS='t.o*' edge_main | grep -E '^==|PASS|WARN|FAIL' | tr '\n' ';')" \
        "== On ==;  WARN  on ran;== Skipped (capability not declared by this image) ==;==================== summary ====================;  PASS: 0   WARN: 1   FAIL: 0;"
    mkdir -p "$T/caps"; printf 'feature-off\nunprobed\n' > "$T/caps/capabilities"
    out=$(EDGE_CHECKS_DIR=$T/caps edge_main); rc=$?
    eq "capabilities file adds to probes (exit)" "$rc" 1
    eq "capabilities file adds to probes" "$(printf '%s\n' "$out" | grep -E '^  (t\.|PASS |WARN |FAIL )' | tr '\n' ';')" \
        "  PASS  core ok;  WARN  on ran;  FAIL  off ran;  WARN  on ran;"
    out=$(EDGE_CHECK_IDS='nothing.*' edge_main 2>&1); rc=$?
    eq "empty selection exits 2" "$rc/$out" "2/no check id matches EDGE_CHECK_IDS='nothing.*' (--list shows them)"
    # A pattern that matches file names in the cwd still matches ids only.
    mkdir -p "$T/cwd"; : > "$T/cwd/t.zzz"
    eq "selection does not glob files" "$(cd "$T/cwd" && EDGE_CHECK_IDS='t.*' edge_main | grep -c '^== [A-Z]')" 3
    block_end
)

# --- invocation forms of the generated scripts --------------------------------

for s in edge-smoke-test.sh edge-verity-check.sh; do
    f=$ROOT/scripts/dev/$s
    a=$(bash "$f" --list); ra=$?
    b=$(bash -s -- --list < "$f"); rb=$?
    eq "$s --list as file" "$ra" 0
    eq "$s --list on stdin" "$rb/$b" "0/$a"
    [ -n "$a" ] && ok || bad "$s --list empty"
    # Sourced: everything defined, nothing run, no output.
    c=$(EDGE_CHECKS_SOURCE_ONLY=1 bash -c '. "$1" && declare -F edge_main >/dev/null && echo defined' _ "$f")
    eq "$s sourced" "$c" defined
    # Every cap: tier has a probe; a missing one would skip its checks silently.
    c=$(EDGE_CHECKS_SOURCE_ONLY=1 bash -c '. "$1"
        for e in "${EDGE_CHECK_REG[@]}"; do
            IFS="|" read -r id tier _ fn <<< "$e"
            declare -F "$fn" >/dev/null || echo "$id: no function $fn"
            case $tier in cap:*) c=${tier#cap:}; declare -F "edge_cap_${c//[^A-Za-z0-9_]/_}" >/dev/null || echo "$id: no probe for $c" ;; esac
        done' _ "$f")
    eq "$s probes and functions" "$c" ""
    # Ids are unique and stable-looking (lowercase dotted).
    eq "$s ids unique" "$(printf '%s\n' "$a" | awk '{print $1}' | sort | uniq -d)" ""
    eq "$s ids well-formed" "$(printf '%s\n' "$a" | awk '{print $1}' | grep -vE '^[a-z0-9-]+(\.[a-z0-9-]+)+$')" ""
done

while read -r p f; do pass=$((pass + p)); fail=$((fail + f)); done < "$T/counts"
[ "$(wc -l < "$T/counts")" -eq 4 ] || bad "a test block did not finish"
echo "edge-checks selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
