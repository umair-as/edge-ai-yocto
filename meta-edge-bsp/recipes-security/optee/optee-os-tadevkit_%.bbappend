# meta-arm's optee-os-tadevkit_4.9.0.bb does `require optee-os_${PV}.bb`,
# which inherits SRC_URI/SRCREV from mainline meta-arm — but bbappend
# filename matching is on the base recipe name (optee-os-tadevkit), so
# optee-os_%.bbappend overrides don't propagate to tadevkit — mirror them here.
# the source/platform overrides in this bbappend separately, or the
# TA dev kit headers/signing-key would be built against mainline
# OP-TEE 4.9.0 while the running OP-TEE binary is Renesas 4.8.0/rz —
# which risks subtle TA-side ABI mismatches (TA struct layouts,
# syscall numbering for plat-rz-specific helpers, signing-key drift).
#
# Keeping this aligned with meta-edge-bsp/recipes-security/optee/optee-os_%.bbappend.
# Source pin and platform flags must match optee-os_%.bbappend.

COMPATIBLE_MACHINE:smarc-rzv2l = "smarc-rzv2l"

SRC_URI:smarc-rzv2l = "git://github.com/renesas-rz/rzg_optee-os.git;protocol=https;branch=4.8.0/rz;name=optee"
SRCREV:smarc-rzv2l  = "82a5cd3b26ed319e8fa72b305462a78417d68daa"
PV:smarc-rzv2l      = "4.8.0+git${SRCPV}"

OPTEEMACHINE:smarc-rzv2l = "rz"

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
