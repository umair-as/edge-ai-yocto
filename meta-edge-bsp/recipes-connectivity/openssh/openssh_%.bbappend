# Replace oe-core's sshd_check_keys-based first-boot host-key generator
# with `ssh-keygen -A`. The upstream sshd_check_keys script:
#
#   1. greps `sshd -G` for HostKey lines (path-prefix-matched against
#      `*_rsa_key`, `*_ecdsa_key`, `*_ed25519_key`),
#   2. for each, runs ssh-keygen in a no-`set -e` shell loop, and
#   3. moves results into place with explicit fsync.
#
# Under transient I/O (NFS root, slow eMMC), one key type can fail
# silently and the loop continues — in practice only ssh_host_ecdsa_key
# was generated. sshd_hardening.conf's
# HostKeyAlgorithms (ssh-ed25519, rsa-sha2-512, rsa-sha2-256) then
# matches nothing, sshd's kex offer is empty, and the image ships with
# SSH structurally locked out.
#
# `ssh-keygen -A` is OpenSSH's idiomatic "generate host keys of all
# default key types if they do not already exist." Single binary call,
# no shell, atomic intent — and even if one type fails, the others
# still land (and the failure surfaces in the unit log rather than
# being papered over).
#
# Restored on next image build via the bbappend's SRC_URI override:
# sshdgenkeys.service ships from this bbappend's files/ dir; the
# upstream copy under openembedded-core is shadowed.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://sshdgenkeys.service"
