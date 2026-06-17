# Opt smarc-rzv2l into meta-arm's optee-examples. The base recipe sets
# COMPATIBLE_MACHINE ?= "invalid" (see
# meta-arm/meta-arm/recipes-security/optee/optee.inc:6) and expects
# BSP layers to opt in per machine.
#
# This recipe ships the Linaro sample CAs + TAs used to smoke-test OP-TEE
# on a new platform:
#   /usr/bin/optee_example_hello_world  (and: random, secure_storage,
#     aes, hotp, acipher)
#   /usr/lib/optee_armtz/<uuid>.ta      (matching TA per example)
#   /usr/lib/tee-supplicant/plugins/    (sample supplicant plugins)
#
# DEPENDS chain pulls optee-os-tadevkit (TA headers + signing key), which
# which optee-os produces.
COMPATIBLE_MACHINE:smarc-rzv2l = "smarc-rzv2l"
