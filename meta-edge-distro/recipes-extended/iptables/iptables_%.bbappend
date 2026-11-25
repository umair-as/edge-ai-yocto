# iptables.service/ip6tables.service restore rules through the legacy
# x_tables engine, which the kernels do not carry (nftables only; netavark uses
# its nftables driver). The package stays: podman RDEPENDS it.
SYSTEMD_AUTO_ENABLE:${PN} = "disable"
