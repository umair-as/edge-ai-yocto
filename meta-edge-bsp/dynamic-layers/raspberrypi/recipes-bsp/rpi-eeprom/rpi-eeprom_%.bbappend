# Newer than the meta-raspberrypi pin (v2026.05.11): carries the A/B-capable
# bootloader-2712 default images and the MFG_VER/target-soc update checks.
SRCREV = "131548b60eaffaf2c5e9b01d6e6f6275ba419034"
PV = "v2026.09.25-2712"

# Pin the EEPROM release channel explicitly instead of inheriting whatever the
# upstream default config ships. "latest" pulls pre-release bootloader images;
# a bootchain updater uses the stable "default" set.
EDGE_RPI_EEPROM_RELEASE_STATUS ?= "default"

# Since this SRCREV, rpi-eeprom-update -a on BCM2712 defaults to an immediate
# flash from Linux, force-committed when rpi-eeprom-ab is present. 0 keeps
# edge-rpi-eeprom "stage": files on /boot, firmware self-update on reboot.
EDGE_RPI_EEPROM_IMMEDIATE_UPDATE ?= "0"
EDGE_RPI_EEPROM_AB ?= "0"

do_install:append() {
    cfg="${D}${sysconfdir}/default/rpi-eeprom-update"
    if [ -f "$cfg" ] && grep -q '^FIRMWARE_RELEASE_STATUS=' "$cfg"; then
        sed -i "s|^FIRMWARE_RELEASE_STATUS=.*|FIRMWARE_RELEASE_STATUS=\"${EDGE_RPI_EEPROM_RELEASE_STATUS}\"|" "$cfg"
    else
        install -d ${D}${sysconfdir}/default
        echo "FIRMWARE_RELEASE_STATUS=\"${EDGE_RPI_EEPROM_RELEASE_STATUS}\"" >> "$cfg"
    fi
    sed -i -e '/^#\?RPI_EEPROM_IMMEDIATE_UPDATE=/d' -e '/^#\?AB_EEPROM=/d' "$cfg"
    echo "RPI_EEPROM_IMMEDIATE_UPDATE=${EDGE_RPI_EEPROM_IMMEDIATE_UPDATE}" >> "$cfg"
    echo "AB_EEPROM=${EDGE_RPI_EEPROM_AB}" >> "$cfg"
}
