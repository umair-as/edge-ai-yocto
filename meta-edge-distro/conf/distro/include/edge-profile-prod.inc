# EDGE_PROFILE = "prod" — production tier defaults.
#
# Required by edge-ai.conf when EDGE_PROFILE = "prod". Operators flip
# the profile via EDGE_PROFILE in kas/local.yml or environment.

# No observability tooling in prod. Operators who want it set
# EDGE_ENABLE_OBSERVABILITY = "1" explicitly.
EDGE_ENABLE_OBSERVABILITY ?= "0"

# Immutable rootfs intent: no runtime package install.
# (Tier images that explicitly want dnf/rpm at runtime can re-add it.)
IMAGE_FEATURES:remove = "package-management"
