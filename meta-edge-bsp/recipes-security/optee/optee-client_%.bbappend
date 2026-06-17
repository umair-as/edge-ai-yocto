# Opt smarc-rzv2l into meta-arm's optee-client. The base recipe sets
# COMPATIBLE_MACHINE ?= "invalid" (see
# meta-arm/meta-arm/recipes-security/optee/optee.inc:6) and expects
# BSP layers to opt in per machine.
#
# This recipe ships:
#   - libteec.so + tee_client_api.h (CA-side userspace API)
#   - tee-supplicant daemon (handles REE-side service calls from TAs)
#   - tee-supplicant@.service systemd unit (templated, started by udev
#     when /dev/teepriv0 appears)
#   - tee / teepriv / teesuppl system users+groups
#
# ABI: meta-arm pins this to v4.9.0; our optee-os is on the Renesas
# 4.8.0/rz fork. OP-TEE's client-side SMC ABI is stable across minor
# versions — the vendor AI SDK pairs an upstream-master optee-client
# with the same 4.8.0 OP-TEE OS fork, so 4.9 client + 4.8 OS is a
# documented vendor combination.
COMPATIBLE_MACHINE:smarc-rzv2l = "smarc-rzv2l"

# Provide /etc/default/tee-supplicant so the unit's EnvironmentFile= line
# resolves OPTARGS. Without it, systemd prints "Referenced but unset
# environment variable evaluates to an empty string: OPTARGS" at every
# template-instance start.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://tee-supplicant.default"

do_install:append() {
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${UNPACKDIR}/tee-supplicant.default \
        ${D}${sysconfdir}/default/tee-supplicant
}

FILES:${PN} += "${sysconfdir}/default/tee-supplicant"
