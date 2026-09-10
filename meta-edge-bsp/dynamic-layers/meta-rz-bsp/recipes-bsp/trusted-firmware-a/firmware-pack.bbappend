# SYSROOT_TFA path correction. meta-renesas's firmware-pack.bb hardcodes
# SYSROOT_TFA = "${RECIPE_SYSROOT}/firmware" — assuming TF-A installs
# directly into /firmware/. Modern meta-arm uses
# FIRMWARE_DIR = "${FIRMWARE_BASE_DIR}/${PN}" → /firmware/trusted-firmware-a/
# (see meta-arm/classes-recipe/firmware.bbclass:14). So bl2.bin / bl31.bin
# / fip.bin land in the sysroot at /firmware/trusted-firmware-a/, not
# /firmware/. firmware-pack's bptool/cat/cp lines all fail trying to read
# from the wrong path. Re-point.
SYSROOT_TFA = "${RECIPE_SYSROOT}/firmware/trusted-firmware-a"
