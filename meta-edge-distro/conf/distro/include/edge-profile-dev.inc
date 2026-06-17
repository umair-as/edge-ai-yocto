# EDGE_PROFILE = "dev" — development tier defaults.
#
# Required by edge-ai.conf when EDGE_PROFILE = "dev". The :dev override
# key in OVERRIDES picks up tier-specific assignments declared elsewhere
# in the layer.

# Observability is on by default on dev (set via :dev override in
# edge-features.inc); restated here for clarity. The ?= respects an
# explicit operator value.
EDGE_ENABLE_OBSERVABILITY ?= "1"

# package-management (dnf/rpm at runtime) stays — it's already in
# edge-image-common.inc IMAGE_FEATURES; the prod profile removes it.
