# fdt_add_pubkey is built by `make cross_tools` but oe-core installs only
# mkimage, mkenvimage, dumpimage, fit_check_sign and mkeficapsule. The
# mainline kernel recipe uses it to put the FIT public key into the board DTB
# that is U-Boot's control FDT on this board (the Renesas U-Boot gets the key
# through concat_dtb instead, which needs the private key at hand).
do_install:append() {
    install -m 0755 tools/fdt_add_pubkey ${D}${bindir}/uboot-fdt_add_pubkey
    ln -sf uboot-fdt_add_pubkey ${D}${bindir}/fdt_add_pubkey
}

FILES:${PN}-mkimage += "${bindir}/uboot-fdt_add_pubkey ${bindir}/fdt_add_pubkey"
