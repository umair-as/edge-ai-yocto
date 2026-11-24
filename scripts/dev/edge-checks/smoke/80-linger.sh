# shellcheck shell=bash
# Lingering user managers start at boot, so rootless Quadlets auto-start.

edge_check containers.linger core "Lingering user managers (boot auto-start)" chk_linger

chk_linger() {
    local u uid
    # Linger markers alone are not enough: logind must start the managers.
    # Its enumeration log is the boot-time signal and survives a later manual
    # recovery of the session.
    if sudo -n journalctl -b -u systemd-logind --no-pager 2>/dev/null \
           | grep -iE 'User enumeration failed|Couldn.t add lingering user' >/dev/null; then
        fail "systemd-logind failed to enumerate lingering users this boot — userdb refused the records (workers started before /etc/machine-id was restored; edge-persistence orders systemd-userdbd after it). Rootless Quadlets won't auto-start until userdbd's workers recycle (~5 min) or \`systemctl restart systemd-userdbd\`"
    else
        pass "systemd-logind enumerated lingering users cleanly this boot"
    fi

    # A user with a login session is active regardless of linger; the
    # non-login principal (edge-ctr) is the meaningful proof.
    for u in edge-ctr devel; do
        uid=$(id -u "${u}" 2>/dev/null || true)
        [ -z "${uid}" ] && { info "${u}: no such user"; continue; }
        if ! sudo -n test -e "/var/lib/systemd/linger/${u}" 2>/dev/null; then
            info "${u}: linger not enabled"
            continue
        fi
        if [ -d "/run/user/${uid}" ] && systemctl is-active "user@${uid}.service" >/dev/null 2>&1; then
            pass "${u} (uid ${uid}): user manager active + /run/user/${uid} present"
        else
            fail "${u} (uid ${uid}): linger marker present but user@${uid} inactive / no /run/user/${uid}"
        fi
    done
}
