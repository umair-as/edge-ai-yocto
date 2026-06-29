# EDGE_PROFILE = "dev" — development tier defaults.
#
# Required by edge-ai.conf when EDGE_PROFILE = "dev". Single home for dev
# tier defaults (edge-features.inc no longer pre-sets them).

# Observability on by default for dev. This ?= is the source of truth; it
# fires because edge-features.inc no longer defaults the variable ahead of
# this include. An explicit operator value (env / local.yml) still wins.
EDGE_ENABLE_OBSERVABILITY ?= "1"

# package-management (dnf/rpm at runtime) stays — it's already in
# edge-image.bbclass IMAGE_FEATURES; the prod profile removes it.

# Dev tier pulls packagegroup-edge-media (via packagegroup-edge-dev), whose
# camera slice brings gstreamer1.0-plugins-ugly-x264 (H.264 software encode)
# — flagged `commercial` (H.264 patents). Accept the flag at the profile
# level so prod (no media stack) doesn't pre-accept it.
LICENSE_FLAGS_ACCEPTED:append = " commercial"
