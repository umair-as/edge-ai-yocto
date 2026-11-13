# meta-arm's optee-os-tadevkit_4.9.0.bb does `require optee-os_${PV}.bb`,
# but bbappends match by recipe name, so optee-os_%.bbappend does not reach
# tadevkit. Without the same source and flags, the TA dev kit headers and
# signing key would be built against mainline OP-TEE 4.9.0 while BL32 runs
# Renesas 4.8.0/rz — TA-side ABI mismatches (struct layouts, plat-rz
# syscall numbering, signing-key drift).
#
# Source pin and platform flags must match optee-os_%.bbappend.

COMPATIBLE_MACHINE:smarc-rzv2l = "smarc-rzv2l"

SRC_URI:smarc-rzv2l = "git://github.com/renesas-rz/rzg_optee-os.git;protocol=https;branch=4.8.0/rz;name=optee"
SRCREV:smarc-rzv2l  = "82a5cd3b26ed319e8fa72b305462a78417d68daa"
PV:smarc-rzv2l      = "4.8.0+git${SRCPV}"

OPTEEMACHINE:smarc-rzv2l = "rz"

# Same CVE backports as optee-os_%.bbappend: identical source, and this
# recipe is the one the image SBOM reports.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:smarc-rzv2l = " file://cve/CVE-2026-71968.patch"

# Same EXTRA_OEMAKE as the optee-os bbappend. The tadevkit recipe runs
# the same OP-TEE compile (separate work-dir from optee-os since PN
# differs), then its do_install just extracts the export-ta_arm64/
# directory instead of the BL32 binaries. Without the same build flags
# the TA dev kit would be compiled with different CFG_ defaults than
# the BL32 it has to interoperate with at runtime.
EXTRA_OEMAKE:append:smarc-rzv2l = " \
    PLATFORM_FLAVOR=g2l_smarc_2 \
    CFG_REE_FS=y \
    CFG_RPMB_FS=n \
    CFG_CRYPTO_WITH_CE=n \
    CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1 \
"
