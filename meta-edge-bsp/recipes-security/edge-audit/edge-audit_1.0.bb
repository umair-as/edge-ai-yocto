SUMMARY     = "EDGE AI OS audit rules (CIS Level-1 baseline)"
DESCRIPTION = "Installs /etc/audit/rules.d/10-edge.rules: a CIS Level-1 ruleset (identity, \
login, sshd policy, kernel modules, time, network config, RAUC slot state) \
without full syscall auditing, locked with -e 2 until the next reboot."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "base"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

SRC_URI = "file://10-edge.rules"

S = "${UNPACKDIR}"

do_install() {
    # Match auditd's mode on /etc/audit (0750); `install -d -m` only sets the
    # final component, so create the parent explicitly to avoid an rpm %dir
    # conflict with the auditd package.
    install -d -m 0750 ${D}${sysconfdir}/audit
    install -d -m 0750 ${D}${sysconfdir}/audit/rules.d
    install -m 0640 ${UNPACKDIR}/10-edge.rules \
        ${D}${sysconfdir}/audit/rules.d/10-edge.rules
}

FILES:${PN} = "${sysconfdir}/audit/rules.d/10-edge.rules"

# audit subsystem userspace comes from meta-security/recipes-security/audit.
# The recipe also enables systemd's audit unit.
RDEPENDS:${PN} = "audit auditd"
