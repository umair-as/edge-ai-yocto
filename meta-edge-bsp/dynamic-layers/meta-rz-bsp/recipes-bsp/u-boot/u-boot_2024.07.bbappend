FILESEXTRAPATHS:prepend := "${EDGE_BSP_LAYERDIR}/recipes-bsp/u-boot/files:"

# meta-renesas's u-boot-renesas.inc sets S = "${WORKDIR}/git", which
# wrynose's do_unpack rejects. Override here (not via kas-patch) to survive bumps.
S = "${UNPACKDIR}/${BP}"

# meta-arm's u-boot_%.bbappend adds devupstream:target pinned to denx
# mainline master; smarc-rzv2l patches fail do_patch against it. :remove
# survives bbappend processing-order variance.
BBCLASSEXTEND:remove = "devupstream:target"

SRC_URI:append = " \
    file://patches/0001-smarc-rzv2l-enable-CONFIG_CMD_PART.patch \
    file://patches/0002-smarc-rzv2l-enable-fit-signature-and-bootcount.patch \
    file://patches/0003-rzg2l-ft_board_setup-add-ethernet-fdt-fixup-and-kaslr-seed.patch \
    file://patches/0004-smarc-rzv2l-dts-add-optee-firmware-node-for-rng.patch \
    file://patches/0005-rzg2l-print-edge-boot-marker.patch \
    file://patches/0006-rzg2l-report-kaslr-seed-outcome.patch \
    file://patches/0007-arm-lib-bootm-fix-unsafe-wdt_overflow-append-to-bootargs.patch \
    file://patches/0008-smarc-rzv2l-drop-legacy-CONFIG_BOOTCOMMAND-define.patch \
"

# U-Boot surface reduction. Three composable features:
#   surface_reduce — usb/storage commands, USB host HCDs, kermit/s-record
#                    load all off. Gadget side (ums eMMC flashing) remains.
#   net_off        — network commands off; net core remains compiled in.
#                    EDGE_DEV_NETBOOT=1 builds skip the fragment.
#   fit_enforce    — regression-guard against legacy uImage re-enablement.
EDGE_UBOOT_FEATURES ?= "surface_reduce net_off fit_enforce"

SRC_URI:append = "${@' file://edge-uboot-hardening.cfg' \
    if 'surface_reduce' in (d.getVar('EDGE_UBOOT_FEATURES') or '') else ''}"

SRC_URI:append = "${@' file://edge-uboot-net-off.cfg' \
    if 'net_off' in (d.getVar('EDGE_UBOOT_FEATURES') or '') \
    and d.getVar('EDGE_DEV_NETBOOT') != '1' else ''}"

SRC_URI:append = "${@' file://edge-uboot-fit-enforce.cfg' \
    if 'fit_enforce' in (d.getVar('EDGE_UBOOT_FEATURES') or '') else ''}"

# Serial-visible boot marker, same scheme and values as the TF-A append so one
# grep over a captured console log yields the whole boot chain in order.
EDGE_BUILD_PROFILE ?= "local"
EDGE_BOOT_VERSION  ?= "${DISTRO_VERSION}"
EDGE_BOOT_PROFILE  ?= "${EDGE_PROFILE}"
EXTRA_OEMAKE:append = " KCPPFLAGS='-DEDGE_BOOT_VERSION=\"${EDGE_BOOT_VERSION}\" -DEDGE_BOOT_PROFILE=\"${EDGE_BOOT_PROFILE}\"'"

# meta-renesas's do_deploy:append:rzg2l-family reads from
# ${B}/<UBOOT_MACHINE>, but oe-core's u-boot.inc now names per-config dirs
# ${B}/<UBOOT_MACHINE>-<UBOOT_CONFIG>. Symlink the legacy path to the real
# dir post-compile so the meta-renesas install resolves through it.
do_compile:append:smarc-rzv2l() {
    legacy="${B}/smarc-rzv2l_defconfig"
    actual="${B}/smarc-rzv2l_defconfig-smarc-rzv2l"
    if [ -d "${actual}" ] && [ ! -e "${legacy}" ]; then
        ln -sf smarc-rzv2l_defconfig-smarc-rzv2l "${legacy}"
    fi
}

# concat_dtb override: oe-core's default builds a dummy FIT with sha1
# during key injection, and mkimage bakes that algo into the embedded
# pubkey node — FIT verification of the signed (sha256) images
# would mismatch. Force the dummy FIT's hash to FIT_HASH_ALG.
concat_dtb() {
	type="$1"
	binary="$2"

	if [ -e "${UBOOT_DTB_BINARY}" ]; then
		dummy_its="${B}/unused-sha256.its"
		cat > "${dummy_its}" << EOF
/dts-v1/;

/ {
	description = "Dummy FIT for U-Boot key injection";
	#address-cells = <1>;

	images {
		kernel-1 {
			description = "dummy";
			data = /incbin/("/dev/null");
			type = "kernel";
			arch = "${UBOOT_ARCH}";
			os = "linux";
			compression = "none";
			load = <0x0>;
			entry = <0x0>;
			hash-1 {
				algo = "${FIT_HASH_ALG}";
			};
		};
	};

	configurations {
		default = "conf-1";
		conf-1 {
			kernel = "kernel-1";
			signature {
				algo = "${FIT_HASH_ALG},${FIT_SIGN_ALG}";
				key-name-hint = "${UBOOT_SIGN_KEYNAME}";
			};
		};
	};
};
EOF

		${UBOOT_MKIMAGE_SIGN} \
			${@'-D "${UBOOT_MKIMAGE_DTCOPTS}"' if len('${UBOOT_MKIMAGE_DTCOPTS}') else ''} \
			-f "${dummy_its}" \
			-k "${UBOOT_SIGN_KEYDIR}" \
			-K "${UBOOT_DTB_BINARY}" \
			-r ${B}/unused.itb \
			${UBOOT_MKIMAGE_SIGN_ARGS}

		${UBOOT_FIT_CHECK_SIGN} \
			-k "${UBOOT_DTB_BINARY}" \
			-f ${B}/unused.itb

		cp ${UBOOT_DTB_BINARY} ${UBOOT_DTB_SIGNED}
	fi

	# Concatenate SPL-less U-Boot binary with the signed DTB.
	if [ "${SPL_SIGN_ENABLE}" != "1" ] ; then
		if [ "x${UBOOT_SUFFIX}" = "ximg" -o "x${UBOOT_SUFFIX}" = "xrom" ] && \
			[ -e "${UBOOT_DTB_BINARY}" ]; then
			oe_runmake EXT_DTB="${UBOOT_DTB_SIGNED}" ${UBOOT_MAKE_TARGET}
			if [ -n "${binary}" ]; then
				cp ${binary} ${UBOOT_BINARYNAME}-${type}.${UBOOT_SUFFIX}
			fi
		elif [ -e "${UBOOT_NODTB_BINARY}" -a -e "${UBOOT_DTB_BINARY}" ]; then
			if [ -n "${binary}" ]; then
				cat ${UBOOT_NODTB_BINARY} ${UBOOT_DTB_SIGNED} | tee ${binary} > \
					${UBOOT_BINARYNAME}-${type}.${UBOOT_SUFFIX}
			else
				cat ${UBOOT_NODTB_BINARY} ${UBOOT_DTB_SIGNED} > ${UBOOT_BINARY}
			fi
		else
			bbwarn "Failure while adding public key to u-boot binary. Verified boot won't be available."
		fi
	fi
}

# Repair the deployed control DTB and nodtb binary.
#
# uboot-sign.bbclass deploy_dtb() (:222-245) installs each artifact as
# u-boot[-nodtb]-${type}-${PV}-${PR} then `ln -sf` it onto UBOOT_{DTB,NODTB}_IMAGE,
# which is u-boot[-nodtb]-${MACHINE}-${PV}-${PR}. smarc-rzv2l.conf:26 sets
# UBOOT_CONFIG ??= "smarc-rzv2l", so type == MACHINE, both names are one string
# and the link replaces the file with a link to itself.
do_deploy:append() {
    signed=$(find ${WORKDIR}/build -name '${UBOOT_DTB_BINARY}-signed' -type f | head -1)
    if [ -z "$signed" ]; then
        bbfatal "No ${UBOOT_DTB_BINARY}-signed under ${WORKDIR}/build; \
UBOOT_SIGN_ENABLE is ${UBOOT_SIGN_ENABLE} but nothing signed the control DTB."
    fi
    install -m 0644 "$signed" ${DEPLOYDIR}/${UBOOT_DTB_IMAGE}
    ln -sf ${UBOOT_DTB_IMAGE} ${DEPLOYDIR}/${UBOOT_DTB_SYMLINK}

    nodtb=$(find ${WORKDIR}/build -name '${UBOOT_NODTB_BINARY}' -type f | head -1)
    if [ -z "$nodtb" ]; then
        bbfatal "No ${UBOOT_NODTB_BINARY} under ${WORKDIR}/build."
    fi
    install -m 0644 "$nodtb" ${DEPLOYDIR}/${UBOOT_NODTB_IMAGE}
    ln -sf ${UBOOT_NODTB_IMAGE} ${DEPLOYDIR}/${UBOOT_NODTB_SYMLINK}
}

# The board's raw env area asserted against the resolved .config -- shared
# with every other U-Boot bbappend.
require ${EDGE_BSP_LAYERDIR}/recipes-bsp/u-boot/edge-uboot-env-assert.inc
