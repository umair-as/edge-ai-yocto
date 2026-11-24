# shellcheck shell=bash
# Persistence binds (edge-persistence): state directories live on /data.

edge_check storage.binds core "Persistence binds (edge-persistence)" chk_binds

# check_bind <path> <expected /data source>: for a bind mount, findmnt FSROOT
# is the subpath alone, so compare it against the /data suffix; works
# whichever device backs /data.
check_bind() {
    local where=$1 expect_source=$2 fsroot expect_subpath src
    if ! findmnt --target "${where}" -no FSROOT >/dev/null 2>&1; then
        fail "${where}: nothing mounted"
        return
    fi
    fsroot=$(findmnt --target "${where}" -no FSROOT | head -1)
    src=$(findmnt --target "${where}" -no SOURCE | head -1)
    expect_subpath="${expect_source#/data}"
    if [ "${fsroot}" = "${expect_subpath}" ]; then
        pass "${where} <- ${src} (fsroot=${fsroot})"
    else
        fail "${where}: fsroot='${fsroot}' source='${src}' (wanted ${expect_source} / fsroot ${expect_subpath})"
    fi
}

chk_binds() {
    check_bind /var/log                  /data/log
    check_bind /var/lib/containers       /data/containers
    check_bind /var/lib/systemd          /data/systemd
    check_bind /home                     /data/home

    # A volatile-log symlink would put the /var/log bind on tmpfs.
    if [ -L /var/log ]; then
        fail "/var/log is still a symlink (FILESYSTEM_PERMS_TABLES drop didn't take)"
    else
        pass "/var/log is a real directory (volatile-log perms-table dropped)"
    fi

    # edge-pstore-persist binds pstore under the /var/lib/systemd bind.
    if findmnt /var/lib/systemd/pstore >/dev/null 2>&1; then
        pass "/var/lib/systemd/pstore bound from $(findmnt -no SOURCE /var/lib/systemd/pstore)"
    else
        warn "/var/lib/systemd/pstore bind missing (kernel crash capture won't persist)"
    fi
}
