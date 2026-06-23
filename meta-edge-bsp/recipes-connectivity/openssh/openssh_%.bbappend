# Replace oe-core's sshd_check_keys-based first-boot host-key generator with a
# minimal ed25519-only fallback. The upstream sshd_check_keys script greps
# `sshd -G` for HostKey lines and runs ssh-keygen in a no-`set -e` shell loop;
# under transient I/O (NFS root, slow eMMC) one key type fails silently and the
# rest are skipped — sshd then offers nothing the client accepts and the image
# ships with SSH structurally locked out.
#
# The edge policy is an ed25519-only HostKey (sshd_hardening.conf), and
# edge-ssh-host-keys-persist is the primary generator (generate-or-restore from
# /data, ordered before this unit). This sshdgenkeys.service is the fallback:
# one ssh-keygen ed25519 call if the /data-backed generation did not run.
#
# Ships from this bbappend's files/ dir; the upstream copy under
# openembedded-core is shadowed.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://sshdgenkeys.service"
