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
#                   the signed slot FIT). Zero IPC vs the
#                   `busctl get-property … BootSlot` D-Bus roundtrip.
#                   Falls back to "external" for NFS-root dev boots
#                   where no rauc.slot= is on the cmdline.
#   Primary IP    : `ip -4 route get 1.1.1.1` — the source address the
#                   kernel would use for default-route egress. Answers
#                   egress IP for default route — address to reach this board on a multi-NIC setup.
#   Hardware      : /sys/firmware/devicetree/base/model. The DT model
#                   string. Live read, no caching.
#   Boot source   : /proc/device-tree/chosen/edge,boot-source, written by
#                   U-Boot on boards that export the boot ROM device; the
#                   line is omitted where the property is absent.
#   Root device   : first /dev/ path of dm-mod.create (verity) or root=,
#                   medium from /sys/block/<disk>/device/type.
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
    # ip(8) is in /sbin, which is not on PATH for non-root console logins.
    _ip="not assigned" _if="" _ipcmd=$(command -v ip 2>/dev/null)
    for _c in /sbin/ip /usr/sbin/ip; do
        [ -z "$_ipcmd" ] && [ -x "$_c" ] && _ipcmd=$_c
    done
    if [ -n "$_ipcmd" ]; then
        _rt=$("$_ipcmd" -4 route get 1.1.1.1 2>/dev/null | head -1)
        if [ -n "$_rt" ]; then
            _ip=$(printf '%s\n' "$_rt" | sed -nE 's/.*src ([0-9.]+).*/\1/p')
            _if=$(printf '%s\n' "$_rt" | sed -nE 's/.*dev ([^ ]+).*/\1/p')
            [ -n "$_ip" ] || _ip="not assigned"
        fi
    fi

    # RAUC slot from /proc/cmdline. Signed slot FITs set rauc.slot=A or =B;
    # NFS-root dev boots do not set it.
    _slot=external
    if [ -r /proc/cmdline ]; then
        _v=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null \
             | sed -nE 's/^rauc\.slot=(.+)$/\1/p' | head -1)
        [ -n "$_v" ] && _slot=$_v
    fi

    _bootsrc=""
    _bs=/proc/device-tree/chosen/edge,boot-source
    if [ -r "$_bs" ]; then
        case "$(tr -d '\0' < "$_bs" 2>/dev/null)" in
            qspi) _bootsrc="QSPI flash" ;;
            esd)  _bootsrc="SD card" ;;
            emmc) _bootsrc="eMMC" ;;
            scif) _bootsrc="SCIF download" ;;
            *)    _bootsrc=unknown ;;
        esac
    fi

    # Root partition: verity backing device from dm-mod.create, else root=.
    _rootdev=""
    if [ -r /proc/cmdline ]; then
        _rootdev=$(sed -nE 's/.*dm-mod\.create="[^"]*(\/dev\/[a-z0-9]+).*/\1/p' /proc/cmdline)
        [ -n "$_rootdev" ] || _rootdev=$(tr ' ' '\n' < /proc/cmdline \
            | sed -nE 's/^root=(\/dev\/[a-z0-9]+)$/\1/p' | head -1)
    fi
    _root=""
    if [ -n "$_rootdev" ]; then
        _part=${_rootdev#/dev/}
        _disk=$(printf '%s\n' "$_part" | sed -E 's/p?[0-9]+$//')
        case "$_part" in mmcblk*|nvme*) _disk=$(printf '%s\n' "$_part" | sed -E 's/p[0-9]+$//') ;; esac
        _medium=$_disk
        if [ -r "/sys/block/$_disk/device/type" ]; then
            case "$(cat "/sys/block/$_disk/device/type")" in
                MMC) _medium=eMMC ;;
                SD)  _medium="SD card" ;;
            esac
        fi
        case "$_disk" in nvme*) _medium=NVMe ;; esac
        _root="$_medium ($_part)"
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
    [ -n "$_bootsrc" ] && printf '    \033[0;33mBoot source: \033[0m%s\n' "$_bootsrc"
    [ -n "$_root" ] && printf '    \033[0;33mRoot device: \033[0m%s\n' "$_root"
    printf '    \033[0;33mRAUC slot:   \033[0m\033[1;32m%s\033[0m\n' "$_slot"
    printf '\033[0;36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '\n'

    unset _hostname _kernel _hw _booted _load _mem_total _mem_avail _ip _if _rt _slot _v _s _d _h _m \
          _bootsrc _bs _rootdev _root _part _disk _medium _ipcmd _c
}

_edge_motd_render
unset -f _edge_motd_render
