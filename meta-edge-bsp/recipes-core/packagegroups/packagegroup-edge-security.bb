SUMMARY     = "Security baseline: audit, SELinux, pwquality, sudo, caps, sftp, crypt, sshd"
DESCRIPTION = "Security userspace in every edge tier: audit, libpwquality, libcap, \
ca-certificates, sftp-server, cryptsetup, sudo, the sshd hardening drop-in \
and the SELinux stack (refpolicy-mcs, selinux-autorelabel)."
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
    packagegroup-core-selinux \
    refpolicy-mcs \
    selinux-autorelabel \
"
