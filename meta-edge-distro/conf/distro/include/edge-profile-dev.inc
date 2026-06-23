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

# Dev tier pulls packagegroup-edge-media (via packagegroup-edge-dev), which
# brings oe-core's gstreamer1.0-plugins-ugly + gstreamer1.0-libav and their
# faac/faad2/mpeg2dec/x264 sub-deps — all flagged `commercial`. Accept the
# flag at the profile level so prod (no media stack) doesn't pre-accept it.
LICENSE_FLAGS_ACCEPTED:append = " commercial"
