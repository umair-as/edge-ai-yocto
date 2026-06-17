SUMMARY     = "Security baseline: audit, pwquality, sudo, caps, sftp, crypt, sshd policy"
DESCRIPTION = "Universal security userspace pulled into every edge tier: \
audit/auditd, libpwquality (PAM), libcap (getcap/setcap), ca-certificates, \
openssh-sftp-server, cryptsetup (veritysetup + LUKS), sudo, and the sshd \
hardening drop-in (edge-sshd-hardening)."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

RDEPENDS:${PN} = " \
    audit \
    auditd \
    libpwquality \
    libcap \
    libcap-bin \
    ca-certificates \
    openssh-sftp-server \
    cryptsetup \
    sudo \
    edge-sshd-hardening \
"
