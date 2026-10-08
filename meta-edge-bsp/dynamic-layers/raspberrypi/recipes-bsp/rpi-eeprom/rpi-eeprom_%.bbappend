# Pin the EEPROM release channel explicitly instead of inheriting whatever the
# upstream default config ships. "latest" pulls pre-release bootloader images;
# a bootchain updater uses the stable "default" set. SRCREV stays the one the
# meta-raspberrypi recipe pins (the bootloader-2712 payload is tied to it).
EDGE_RPI_EEPROM_RELEASE_STATUS ?= "default"

do_install:append() {
    cfg="${D}${sysconfdir}/default/rpi-eeprom-update"
    if [ -f "$cfg" ] && grep -q '^FIRMWARE_RELEASE_STATUS=' "$cfg"; then
        sed -i "s|^FIRMWARE_RELEASE_STATUS=.*|FIRMWARE_RELEASE_STATUS=\"${EDGE_RPI_EEPROM_RELEASE_STATUS}\"|" "$cfg"
    else
        install -d ${D}${sysconfdir}/default
        echo "FIRMWARE_RELEASE_STATUS=\"${EDGE_RPI_EEPROM_RELEASE_STATUS}\"" >> "$cfg"
    fi
}
