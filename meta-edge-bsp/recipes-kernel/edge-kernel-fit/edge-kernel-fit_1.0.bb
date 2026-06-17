SUMMARY     = "Signed FIT image for the edge-ai distro on RZ/V2L"
DESCRIPTION = "Assembles a U-Boot FIT image (kernel + DTB + signed config \
node) for smarc-rzv2l using the wrynose kernel-fit-image class. Consumes \
linux.bin / DTB / linux_comp artifacts published by linux-renesas via its \
kernel-fit-extra-artifacts class. Replaces the pre-wrynose pattern where \
the kernel recipe itself ran do_assemble_fitimage; that task no longer \
exists on the kernel recipe in OE-Core wrynose."
HOMEPAGE    = "https://github.com/umair-as/edge-ai-yocto"
SECTION     = "kernel"
LICENSE     = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit kernel-fit-image

COMPATIBLE_MACHINE = "smarc-rzv2l"

# Kernel entry + load address. EDGE_FIT_* live at conf level (set in
# kas/machines/<board>.yml's local_conf_header.boot block) so this
# recipe AND linux-renesas see the same values. The recipe is
# COMPATIBLE_MACHINE-gated to smarc-rzv2l (above), so EDGE_FIT_* will
# always carry the RZ/V2L value at build time on this recipe.
UBOOT_LOADADDRESS = "${EDGE_FIT_LOADADDRESS}"
UBOOT_ENTRYPOINT  = "${EDGE_FIT_ENTRYPOINT}"

# Single-DTB v0; the kernel deploys r9a07g054l2-smarc.dtb (set via
# KERNEL_DEVICETREE in meta-rz-bsp's smarc-rzv2l.conf). The class
# auto-builds a /configurations/conf-<dtb-name> node and we make it
# the default so U-Boot's `bootm` without an explicit config name
# selects this one.
FIT_CONF_DEFAULT_DTB = "r9a07g054l2-smarc.dtb"

# Signing — FIT_KERNEL_SIGN_* default to UBOOT_SIGN_* in image-fitimage.conf,
# but pin explicitly here so a future edge.conf change to UBOOT_SIGN_*
# doesn't silently drift this recipe. With UBOOT_SIGN_ENABLE=1 the class
# adds a signature-1 node under /configurations/conf-* signing both kernel
# and fdt images (FIT_SIGN_INDIVIDUAL=0 -> config-level signature only;
# enough for boot-time integrity verification by U-Boot).
FIT_KERNEL_SIGN_ENABLE  = "${UBOOT_SIGN_ENABLE}"
FIT_KERNEL_SIGN_KEYNAME = "${UBOOT_SIGN_KEYNAME}"
FIT_KERNEL_SIGN_KEYDIR  = "${UBOOT_SIGN_KEYDIR}"
