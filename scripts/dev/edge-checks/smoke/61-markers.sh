# shellcheck shell=bash
# Cross-slot marker: a file written in $HOME on one slot must be readable
# from /data on the other, after an OTA (identity files are covered above).

edge_check persist.home-marker core "Cross-slot persistence markers" chk_home_marker

chk_home_marker() {
    local home_marker="${HOME}/edge-smoke-marker" data_home_marker
    if [ ! -f "${home_marker}" ]; then
        echo "edge-smoke $(date -Is) $(uname -n)" > "${home_marker}" 2>/dev/null \
            && pass "wrote ${home_marker}" \
            || fail "could not write ${home_marker}"
    else
        info "${home_marker}: $(cat "${home_marker}")"
    fi

    data_home_marker="/data/home/$(basename "${HOME}")/edge-smoke-marker"
    if [ -f "${data_home_marker}" ] || sudo -n test -f "${data_home_marker}" 2>/dev/null; then
        pass "marker visible at ${data_home_marker} (proves /home bind on /data)"
    else
        warn "marker not yet at ${data_home_marker}"
    fi
}
