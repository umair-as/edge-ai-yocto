# Opt smarc-rzv2l into meta-arm's optee-test (xtest). The base recipe sets
# COMPATIBLE_MACHINE ?= "invalid" (see
# meta-arm/meta-arm/recipes-security/optee/optee.inc:6) and expects BSP
# layers to opt in per machine.
#
# xtest is the OP-TEE conformance suite — GP TEE Internal API tests,
# crypto regression, IPC stress, etc. ~10 MB binary; only on the dev
# image (edge-image-dev), not in the base. ABI: meta-arm pins this to
# v4.9.0; our optee-os is on the Renesas 4.8.0/rz fork. Same client-side
# ABI stability argument as optee-client / optee-examples (see those
# bbappends for the full rationale).
COMPATIBLE_MACHINE:smarc-rzv2l = "smarc-rzv2l"
