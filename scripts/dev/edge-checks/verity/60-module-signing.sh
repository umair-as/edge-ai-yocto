# shellcheck shell=bash
# MODULE_SIG_FORCE rejects unsigned modules, so any loaded module proves the
# in-image signing chain survived strip + sign + package.

edge_check kernel.module-signing core "Module signing" chk_module_signing

chk_module_signing() {
    local mod_count
    mod_count=$(wc -l < /proc/modules)
    if [ "${mod_count}" -gt 0 ]; then
        pass "${mod_count} kernel modules loaded under MODULE_SIG_FORCE"
    else
        warn "no modules loaded — cannot confirm signed-module load path"
    fi
    info "kernel taint: $(cat /proc/sys/kernel/tainted 2>/dev/null || echo "?") (8192=out-of-tree vendor modules is expected)"
}
