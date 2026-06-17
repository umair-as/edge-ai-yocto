# Use the Renesas fork: mainline 4.9.0 has no plat-rz (rzg2l-family).
# Source mirrors the TF-A choice in
# meta-edge-bsp/recipes-bsp/trusted-firmware-a/.

COMPATIBLE_MACHINE:smarc-rzv2l = "smarc-rzv2l"

# Pin to 4.8.0/rz branch; bump SRCREV in lockstep with TF-A (FIP packs
# this as BL32). PV override aligns the package version with the branch
# (meta-arm names the recipe 4.9.0).
SRC_URI:smarc-rzv2l = "git://github.com/renesas-rz/rzg_optee-os.git;protocol=https;branch=4.8.0/rz;name=optee"
SRCREV:smarc-rzv2l  = "82a5cd3b26ed319e8fa72b305462a78417d68daa"
PV:smarc-rzv2l      = "4.8.0+git${SRCPV}"

OPTEEMACHINE:smarc-rzv2l = "rz"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:smarc-rzv2l = " \
    file://0001-plat-rz-hw_rng_tsip-cast-memcpy-dst-back-to-void.patch \
    file://0002-plat-rz-g2l-relax-int-conversion-errors-for-gcc-14-.patch \
"

# CFG_RPMB_FS=n: no RPMB key provisioning wired. CFG_CRYPTO_WITH_CE=n:
# ARM Crypto Extensions path doesn't compile against plat-rz.
# CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1: OpenSSL 3 host-side workaround.
EXTRA_OEMAKE:append:smarc-rzv2l = " \
    PLATFORM_FLAVOR=g2l_smarc_2 \
    CFG_REE_FS=y \
    CFG_RPMB_FS=n \
    CFG_CRYPTO_WITH_CE=n \
    CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1 \
"

# Wires Secure IP HW RNG into OP-TEE; CFG_HWRNG_PTA exposes it to
# U-Boot's optee_rng for /chosen/kaslr-seed at boot.
ENABLE_RZ_SCE              ?= "0"
ENABLE_RZ_SCE:smarc-rzv2l  ?= "1"

EXTRA_OEMAKE:append:smarc-rzv2l = "${@oe.utils.conditional('ENABLE_RZ_SCE', '1', ' CFG_RZ_SCE=y CFG_RZ_SCE_LIB_DIR=${STAGING_LIBDIR} CFG_HWRNG_PTA=y CFG_HWRNG_QUALITY=1024 CFG_WITH_SOFTWARE_PRNG=n', '', d)}"
DEPENDS:append:smarc-rzv2l = "${@oe.utils.conditional('ENABLE_RZ_SCE', '1', ' libsecureip', '', d)}"

# Republish the OP-TEE binary at the path the TF-A bbappend expects
# (RECIPE_SYSROOT/boot/tee-${MACHINE}.bin). meta-arm's optee-os.inc
# installs to /lib/firmware by default; this adds a /boot/ copy with
# the Renesas naming convention so the FIP packs it as BL32 without
# modifying the TF-A bbappend's BL32 path.
do_install:append:smarc-rzv2l() {
    install -d ${D}/boot
    if [ -e ${B}/core/tee-raw.bin ]; then
        install -m 0644 ${B}/core/tee-raw.bin ${D}/boot/tee-${MACHINE}.bin
    elif [ -e ${B}/core/tee.bin ]; then
        install -m 0644 ${B}/core/tee.bin     ${D}/boot/tee-${MACHINE}.bin
    else
        bbfatal "OP-TEE did not produce tee-raw.bin or tee.bin in ${B}/core/. \
Check PLATFORM_FLAVOR (currently g2l_smarc_2) against \
core/arch/arm/plat-rz/conf.mk in the workspace source tree. Documented \
fallback if unrecoverable: flip ENABLE_SPD_OPTEE=0 in the TF-A bbappend \
(BL2 -> BL31 -> U-Boot -> Linux without BL32)."
    fi
}

SYSROOT_DIRS:append:smarc-rzv2l = " /boot"
FILES:${PN}:append:smarc-rzv2l = " /boot/tee-${MACHINE}.bin"

# tee.elf carries debug info with absolute workdir paths the OE prefix-map
# can't fully strip on this Renesas build. Image consumes tee.bin, not the elf.
INSANE_SKIP:${PN}:append:smarc-rzv2l = " buildpaths"
