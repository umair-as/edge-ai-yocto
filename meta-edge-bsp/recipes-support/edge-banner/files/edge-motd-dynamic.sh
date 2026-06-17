# shellcheck shell=sh
# /etc/profile.d/edge-motd-dynamic.sh — sourced by interactive shells
# (login or SSH) after /etc/motd has been printed by login(1)/sshd.
#
# Prints a small dynamic appendix with live system state. Designed to
# cost under 50 ms total: only procfs / sysfs reads + one `ip route get`.
# No D-Bus calls, no `rauc` CLI, no `busctl` — the boot critical chain
# stays clean and login is still cheap.
#
# Source-of-truth choices (why these, not the obvious alternative):
#   RAUC slot     : parsed from /proc/cmdline (`rauc.slot=A` is set by
#                   U-Boot's rauc_set_bootargs macro). Zero IPC vs the
#                   `busctl get-property … BootSlot` D-Bus roundtrip.
#                   Falls back to "external" for NFS-root dev boots
#                   where no rauc.slot= is on the cmdline.
#   Primary IP    : `ip -4 route get 1.1.1.1` — the source address the
#                   kernel would use for default-route egress. Answers
#                   egress IP for default route — address to reach this board on a multi-NIC setup.
#   Hardware      : /sys/firmware/devicetree/base/model. The DT model
#                   string. Live read, no caching.
#   Boot time     : /proc/uptime, formatted via `uptime -p`. Honest at
#                   the moment of login (vs the previous static-snapshot
#                   "Booted: T+0" idiom that was always 0 minutes).

# Only emit for interactive shells. PS1 unset = non-interactive.
case "$-" in
    *i*) ;;
    *)   return 0 2>/dev/null || exit 0 ;;
esac

# Resilient reads — individual failures don't abort the login.
_edge_motd_render() {
    _hostname=$(hostname 2>/dev/null || echo unknown)
    _kernel=$(uname -r 2>/dev/null || echo unknown)

    _hw=unknown
    if [ -r /sys/firmware/devicetree/base/model ]; then
        _hw=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null)
    fi
    [ -n "$_hw" ] || _hw=unknown

    # Compute uptime from /proc/uptime directly. Busybox `uptime` (in the
    # base image) does not implement the `-p` "pretty" flag — using it
    # silently emits an empty string and the banner shows "unknown".
    _booted=unknown
    if [ -r /proc/uptime ]; then
        _s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        if [ -n "$_s" ]; then
            _d=$(( _s / 86400 ))
            _h=$(( (_s % 86400) / 3600 ))
            _m=$(( (_s % 3600) / 60 ))
            if [ "$_d" -gt 0 ]; then
                _booted=$(printf '%dd %dh %dm' "$_d" "$_h" "$_m")
            elif [ "$_h" -gt 0 ]; then
                _booted=$(printf '%dh %dm' "$_h" "$_m")
            else
                _booted=$(printf '%dm' "$_m")
            fi
        fi
    fi

    _load=unknown
    if [ -r /proc/loadavg ]; then
        _load=$(awk '{printf "%s, %s, %s", $1, $2, $3}' /proc/loadavg)
    fi

    _mem_total=? _mem_avail=?
    if [ -r /proc/meminfo ]; then
        _mem_total=$(awk '/MemTotal:/ {printf "%.1f GB", $2/1024/1024; exit}' /proc/meminfo)
        _mem_avail=$(awk '/MemAvailable:/ {printf "%.1f GB", $2/1024/1024; exit}' /proc/meminfo)
    fi

    # Use sed (POSIX BRE/ERE) not gawk's match($0,/.../,arr) — busybox awk
    # in the base image doesn't carry the 3-arg match() form.
    _ip="not assigned" _if=""
    if command -v ip >/dev/null 2>&1; then
        _rt=$(ip -4 route get 1.1.1.1 2>/dev/null | head -1)
        if [ -n "$_rt" ]; then
            _ip=$(printf '%s\n' "$_rt" | sed -nE 's/.*src ([0-9.]+).*/\1/p')
            _if=$(printf '%s\n' "$_rt" | sed -nE 's/.*dev ([^ ]+).*/\1/p')
            [ -n "$_ip" ] || _ip="not assigned"
        fi
    fi

    # RAUC slot from /proc/cmdline. U-Boot's rauc_set_bootargs sets
    # rauc.slot=A or =B on MMC boots. NFS-root dev boots don't set it.
    _slot=external
    if [ -r /proc/cmdline ]; then
        _v=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null \
             | sed -nE 's/^rauc\.slot=(.+)$/\1/p' | head -1)
        [ -n "$_v" ] && _slot=$_v
    fi

    printf '\033[0;36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '    \033[0;33mHost:        \033[0m%s\n' "$_hostname"
    printf '    \033[0;33mHardware:    \033[0m%s\n' "$_hw"
    printf '    \033[0;33mKernel:      \033[0m%s\n' "$_kernel"
    printf '    \033[0;33mUptime:      \033[0m%s\n' "$_booted"
    printf '    \033[0;33mLoad:        \033[0m%s\n' "$_load"
    printf '    \033[0;33mMemory:      \033[0m%s available / %s total\n' "$_mem_avail" "$_mem_total"
    if [ -n "$_if" ]; then
        printf '    \033[0;33mPrimary IP:  \033[0m%s (%s)\n' "$_ip" "$_if"
    else
        printf '    \033[0;33mPrimary IP:  \033[0m%s\n' "$_ip"
    fi
    printf '    \033[0;33mRAUC slot:   \033[0m\033[1;32m%s\033[0m\n' "$_slot"
    printf '\033[0;36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '\n'

    unset _hostname _kernel _hw _booted _load _mem_total _mem_avail _ip _if _rt _slot _v _s _d _h _m
}

_edge_motd_render
unset -f _edge_motd_render
