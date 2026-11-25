# shellcheck shell=bash
# Packet filtering is nftables only: the symbols container-storage-net.cfg and
# xtables-legacy-off.cfg turn off stay off, and no legacy x_tables table
# module is loaded. A symbol the kernel does not have
# (NETFILTER_XTABLES_LEGACY before 6.17) counts as off.

edge_check kernel.nftables-only core "Kernel config: nftables only (no legacy x_tables)" chk_nftables_only

EDGE_LEGACY_XTABLES_SYMS="IP_NF_IPTABLES_LEGACY IP_NF_FILTER IP_NF_NAT IP_NF_MANGLE IP_NF_RAW
IP_NF_SECURITY IP_NF_ARPTABLES IP_NF_ARPFILTER IP6_NF_IPTABLES_LEGACY
IP6_NF_FILTER IP6_NF_NAT IP6_NF_MANGLE IP6_NF_RAW IP6_NF_SECURITY
BRIDGE_NF_EBTABLES_LEGACY BRIDGE_EBT_BROUTE BRIDGE_EBT_T_FILTER
BRIDGE_EBT_T_NAT NETFILTER_XT_NAT NETFILTER_XT_TARGET_MASQUERADE
NETFILTER_XT_MATCH_BPF NETFILTER_XTABLES_LEGACY IPVLAN NET_L3_MASTER_DEV"

chk_nftables_only() {
    local kcfg on="" sym n legacy_mods
    kcfg=$(kconfig_text)
    if ! printf '%s\n' "${kcfg}" | grep '^CONFIG_' >/dev/null; then
        warn "kernel config not readable (/proc/config.gz, /boot/config-$(uname -r)); not checked"
    else
        for sym in ${EDGE_LEGACY_XTABLES_SYMS}; do
            if printf '%s\n' "${kcfg}" | grep -E "^CONFIG_${sym}=(y|m)$" >/dev/null; then
                on="${on} ${sym}"
            fi
        done
        n=$(printf "%s" "${EDGE_LEGACY_XTABLES_SYMS}" | wc -w)
        if [ -z "${on}" ]; then
            pass "all ${n} legacy x_tables/IPVLAN symbols off"
        else
            fail "expected off, enabled:${on}"
        fi
        if printf '%s\n' "${kcfg}" | grep -E '^CONFIG_NF_TABLES=(y|m)$' >/dev/null; then
            pass "CONFIG_NF_TABLES enabled"
        else
            fail "CONFIG_NF_TABLES not enabled: no packet filtering for netavark/nft"
        fi
    fi
    legacy_mods=$(awk '$1 ~ /^(ip_tables|ip6_tables|arp_tables|ebtables|iptable_[a-z]+|ip6table_[a-z]+)$/ {print $1}' /proc/modules 2>/dev/null | xargs)
    if [ -z "${legacy_mods}" ]; then
        pass "no legacy x_tables table modules loaded"
    else
        fail "legacy x_tables modules loaded: ${legacy_mods}"
    fi
}
