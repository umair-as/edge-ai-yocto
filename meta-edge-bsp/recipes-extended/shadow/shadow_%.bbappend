# newuidmap/newgidmap are setuid-root helpers (mode 04755, /usr/bin) that
# rootless podman requires to apply subordinate uid/gid ranges. They ship in
# the main shadow package, which a read-only-rootfs image force-erases via
# ROOTFS_RO_UNNEEDED (to drop useradd/passwd, pointless on a RO root). That
# erase takes newuidmap/newgidmap with it, so rootless multi-id containers
# fail with "newuidmap: executable file not found". Split the two helpers into
# shadow-uidmap, which ROOTFS_RO_UNNEEDED does not name and so survives; the
# setuid bit travels with the files. packagegroup-edge-containers RDEPENDS it.
# The subuid/subgid range files are provisioned separately by edge-users.inc.
PACKAGES =+ "${PN}-uidmap"
FILES:${PN}-uidmap = "${bindir}/newuidmap ${bindir}/newgidmap"
