FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# oe-core u-boot 2026.01 with meta-raspberrypi's rpi_arm64_config. Everything
# this board needs on top is Kconfig, merged from the fragments below: no
# source patch. The RAUC boot chain itself is the managed environment
# (rauc-uboot-env, seeded on first boot); CONFIG_BOOTCOMMAND covers fresh media.
SRC_URI:append:raspberrypi5 = " file://edge-rpi5-boot.cfg"

# U-Boot surface reduction, same three tokens as the RZ/V2L bbappend:
#   surface_reduce — USB host, serial download, DFU off. Boot is SD only.
#   net_off        — network commands off; EDGE_DEV_NETBOOT=1 builds skip it.
#   fit_enforce    — legacy image format off, fresh-media signed-FIT bootcmd.
EDGE_UBOOT_FEATURES ?= "surface_reduce net_off fit_enforce"

SRC_URI:append:raspberrypi5 = "${@' file://edge-rpi5-hardening.cfg' \
    if 'surface_reduce' in (d.getVar('EDGE_UBOOT_FEATURES') or '') else ''}"

SRC_URI:append:raspberrypi5 = "${@' file://edge-rpi5-net-off.cfg' \
    if 'net_off' in (d.getVar('EDGE_UBOOT_FEATURES') or '') \
    and d.getVar('EDGE_DEV_NETBOOT') != '1' else ''}"

SRC_URI:append:raspberrypi5 = "${@' file://edge-rpi5-fit-enforce.cfg' \
    if 'fit_enforce' in (d.getVar('EDGE_UBOOT_FEATURES') or '') else ''}"

# The board's raw env area asserted against the resolved .config -- shared
# with every other U-Boot bbappend.
require ${EDGE_BSP_LAYERDIR}/recipes-bsp/u-boot/edge-uboot-env-assert.inc
