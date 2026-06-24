# Operator-facing toggles for the edge-ai distro.
#
# All declared with ?= so kas/local.yml or environment overrides win.
# Operator-flippable values are added to BB_ENV_PASSTHROUGH_ADDITIONS
# so they can be set per-invocation without editing files.

# ----- Choice variables (string-valued) ------------------------------------

# Image tier. Drives OVERRIDES (:prod / :dev) and the profile include.
# Resolved at distro-parse — set it in the environment (Makefile targets
# export it via BB_ENV_PASSTHROUGH_ADDITIONS) or kas/local.yml, not in an
# image recipe (an image-recipe assignment is too late for the require below
# in edge-ai.conf). Default is dev; prod is an explicit opt-in for release.
EDGE_PROFILE ?= "dev"

# OTA backend. Drives the ota-${EDGE_OTA_BACKEND}.inc include and the
# matching DISTRO_FEATURE / image install set. An unknown value fails
# bitbake at parse with a clear "Could not include..." error — that
# failure mode IS the validation.
EDGE_OTA_BACKEND ?= "rauc"

# ----- Boolean toggles -----------------------------------------------------

# Display stack (wayland + opengl in DISTRO_FEATURES; weston in image).
EDGE_ENABLE_DISPLAY ?= "1"

# Container userspace. Kernel-side cgroup / overlay / netns support is
# already on via kernel fragments; this toggle gates the userspace runtime.
EDGE_ENABLE_CONTAINERS ?= "0"

# DRP-AI accelerator stack (RZ/V2L only). Gates packagegroup-edge-ai: the
# drpai kernel driver + u-dma-buf. Kernel-side CMA/DMABUF is already on via
# ai-compute.cfg; the drpai DT node + reserved memory come from the BSP.
EDGE_ENABLE_AI ?= "0"

# Profiling / observability tooling (htop, sysstat, trace-cmd, ...).
# Tier default lives in edge-profile-{dev,prod}.inc (the correctly-selected
# include). Not defaulted here: a ?= in this file is parsed before the profile
# include, so it would pre-empt the profile inc's ?= and force the old strong
# :dev override. Operator env/local.yml still wins over the profile default.

# Dev-only netboot. When 1, rauc-uboot-env installs a `netboot` macro
# in the managed U-Boot env defaults; bootcmd is unchanged.
EDGE_DEV_NETBOOT ?= "0"

# ----- Toggles declared at recipe scope (listed here for visibility) -------

# EDGE_DEV_DBG_PKGS         — edge-image-dev: dbg-pkgs IMAGE_FEATURE
# EDGE_KERNEL_DEV_FRAGMENTS — linux-renesas: observability-dev.cfg fragment

# ----- Passthrough so operators can flip from the environment --------------

BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_PROFILE EDGE_OTA_BACKEND"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_ENABLE_DISPLAY EDGE_ENABLE_CONTAINERS EDGE_ENABLE_OBSERVABILITY EDGE_ENABLE_AI"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_DEV_NETBOOT EDGE_DEV_DBG_PKGS EDGE_KERNEL_DEV_FRAGMENTS"

# RAUC / OTA knobs — declared in their respective recipes (rauc-conf-edge,
# edge-bundle-common.inc, ota-certs). Passthrough so operators can flip
# them from the environment without editing kas/local.yml.
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_RAUC_STREAMING_KEY_MODE EDGE_RAUC_PKCS11_TLS_KEY"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_RAUC_KEYRING_CERTS EDGE_RAUC_ALLOWED_SIGNER_CNS EDGE_RAUC_CHECK_PURPOSE"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION EDGE_RAUC_ENCRYPTION_KEY EDGE_RAUC_ENCRYPTION_CERT"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS EDGE_OTA_CERT_DIR"
