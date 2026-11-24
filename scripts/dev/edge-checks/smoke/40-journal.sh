# shellcheck shell=bash
# journald writes persistently to /data under the live machine id.

edge_check persist.journal core "journald persistence" chk_journal

chk_journal() {
    local mid_dir=/var/log/journal journal_file boot_count cur_boot mid mid_dirs
    if [ ! -d /run/log/journal ] || [ -z "$(ls -A /run/log/journal 2>/dev/null)" ]; then
        pass "no runtime-only journals on /run (writes go straight to /data)"
    else
        fail "journals on /run — bind didn't shadow tmpfs"
        ls -la /run/log/journal/ | sed 's/^/        /'
    fi

    if [ -d "${mid_dir}" ] && [ -n "$(ls -A "${mid_dir}" 2>/dev/null)" ]; then
        journal_file=$(find "${mid_dir}" -maxdepth 2 -name 'system.journal' | head -1)
        if [ -n "${journal_file}" ]; then
            pass "system.journal present at ${journal_file}"
            info "size: $(du -sh "${journal_file}" | awk '{print $1}')"
        else
            fail "machine-id dir present but no system.journal"
        fi
    else
        fail "${mid_dir} empty — journald isn't writing persistently"
    fi

    if find /data/log/journal -maxdepth 2 -name 'system.journal' 2>/dev/null | grep . >/dev/null; then
        pass "/data/log/journal populated (real persistence path)"
    else
        fail "/data/log/journal empty — bind not working"
    fi

    boot_count=$(journalctl --list-boots --no-pager 2>/dev/null | wc -l)
    info "boots recorded: ${boot_count}"
    if [ "${boot_count}" -ge 2 ]; then
        pass "journal history spans ${boot_count} boots"
    else
        warn "only ${boot_count} boot recorded — reboot at least once to prove persistence"
    fi

    # journald names its directory by the machine id it read at start; a
    # current-boot journal journalctl cannot see was written under a
    # transient id that was replaced later.
    cur_boot=$(tr -d '-' < /proc/sys/kernel/random/boot_id)
    if journalctl --list-boots --no-pager 2>/dev/null | grep "${cur_boot}" >/dev/null; then
        pass "journalctl --list-boots includes the current boot"
    else
        fail "current boot ${cur_boot} missing from journalctl --list-boots (journal written under another machine id?)"
    fi
    mid=$(cat /etc/machine-id 2>/dev/null)
    mid_dirs=$(ls -1 "${mid_dir}" 2>/dev/null | wc -l)
    if [ "${mid_dirs}" -eq 1 ] && [ -d "${mid_dir}/${mid}" ]; then
        pass "exactly one journal directory and it is the live machine id"
    else
        fail "${mid_dir} has ${mid_dirs} entries; expected only ${mid}"
        ls -1 "${mid_dir}" 2>/dev/null | sed 's/^/        /'
    fi
}
