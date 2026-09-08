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

# Container userspace. Baseline for every image tier and every machine: the
# accelerator runtimes ship Quadlet units, and a device that cannot run them
# has the inference path present but dead. Kernel-side cgroup / overlay /
# netns support is already on via kernel fragments; this gates the userspace
# runtime and its principal.
#
# Left as a toggle rather than hardcoded so a product image that genuinely
# runs no containers can drop the whole packagegroup, but 1 is the default
# and prod is not an exception -- see ADR-0012.
EDGE_ENABLE_CONTAINERS ?= "1"

# Accelerator selection. Single-valued on purpose: one populated accelerator
# per image is what the platform builds, and widening a single value to a list
# later is a smaller change than un-picking a list nobody validated.
#
#   EDGE_ACCEL            what this image is built for; set by kas/accel/<name>.yml
#   EDGE_ACCEL_SUPPORTED  what THIS machine can carry; set by the board include
#
# The pair is checked in edge-image.bbclass: an unsupported combination is a
# parse error naming both values, never a quietly accelerator-less image.
EDGE_ACCEL           ?= "none"
EDGE_ACCEL_SUPPORTED ?= ""

# Supplementary groups the accelerator's runtime principal needs. Applied at
# image assembly by edge-users.inc, not by a recipe useradd: the groups are
# created by other recipes and a recipe-level --groups races their creation.
EDGE_ACCEL_SUPPLEMENTARY_GROUPS ?= ""

# Derived, read-only compatibility alias for EDGE_ACCEL. Retained so
# scripts/dev/edge-smoke-test.sh and the docs keep their meaning; deliberately
# not writable, because two sources of truth for "is the accelerator on" is
# how the machine-unscoped injection defect arose in the first place. Removed
# from BB_ENV_PASSTHROUGH_ADDITIONS below for the same reason -- a shell
# override would silently re-introduce the second source.
EDGE_ENABLE_AI = "${@'0' if (d.getVar('EDGE_ACCEL') or 'none') == 'none' else '1'}"

# OP-TEE normal-world userspace. On by default for boards that wire BL32 — the
# secure world is unreachable from Linux without the client stack — but a build
# that never enters the TEE drops the whole packagegroup with this at 0.
EDGE_ENABLE_OPTEE ?= "1"

# OP-TEE demo TAs (optee-examples). Off by default: they are loadable TAs signed
# with the default devkit key, useful for bring-up and unused by any workload,
# so shipping them widens the secure-world attack surface for no return.
EDGE_ENABLE_OPTEE_EXAMPLES ?= "0"

# Profiling / observability tooling (htop, sysstat, trace-cmd, ...).
# Tier default lives in edge-profile-{dev,prod}.inc (the correctly-selected
# include). Not defaulted here: a ?= in this file is parsed before the profile
# include, so it would pre-empt the profile inc's ?= and force the old strong
# :dev override. Operator env/local.yml still wins over the profile default.

# Dev-only netboot. When 1, rauc-uboot-env installs a `netboot` macro
# in the managed U-Boot env defaults; bootcmd is unchanged.
EDGE_DEV_NETBOOT ?= "0"

# RAUC crypt-format bundles. When 1 the bundle payload is AES-256 encrypted
# and the manifest is CMS-enveloped to EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS;
# system.conf widens bundle-formats to "verity crypt" (an allowlist, not a
# replacement -- a fielded device must keep accepting verity through its
# own transition bundle) and gains an [encryption] stanza. Recipient key
# paths default in edge-floor.inc. On by default: the
# shipping target is crypt-format bundles. do_install in ota-certs and
# do_bundle in edge-bundle-common.inc both bbfatal with a pointer to
# scripts/rauc-init-certs.sh if the recipient key material under
# keys/dev/rauc/ does not exist yet, so a fresh checkout's first build fails
# fast and legibly rather than silently shipping an unencrypted image.
#
# Consequence of the default: every default image now carries the same
# shared recipient private key at /etc/ota/bundle-decrypt.key. ADR-0009 is
# explicit that this is a development/integration baseline, not a
# per-device revocation design — offline image access or a root compromise
# on any one device discloses the key for the whole fleet. Fine for the
# current single-board tree; revisit before a real fleet rollout.
EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "1"

# Declared at this global scope, not just in edge-bundle-common.inc (which
# also carries an identical, now-redundant ?= as a standalone-recipe
# fallback), so that rauc-conf-edge -- a different recipe, with its own
# isolated datastore -- can also read it. rauc-conf-edge's system.conf
# allowlist (EDGE_RAUC_BUNDLE_FORMATS) must include whatever format the
# bundle recipe actually emits (EDGE_RAUC_BUNDLE_FORMAT), or every bundle
# this build produces is rejected on install; that cross-check needs both
# variables visible from the same recipe.
EDGE_RAUC_BUNDLE_FORMAT ?= "${@bb.utils.contains('EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION', '1', 'crypt', 'verity', d)}"

# ----- Toggles declared at recipe scope (listed here for visibility) -------

# EDGE_DEV_DBG_PKGS         — edge-image-dev: dbg-pkgs IMAGE_FEATURE
# EDGE_KERNEL_DEV_FRAGMENTS — linux-renesas: observability-dev.cfg fragment
# EDGE_ENABLE_JTAG_DEBUG    — linux-renesas: jtag-debug.cfg fragment;
#                             edge-image-dev: ships edge-debug-mode drop-ins
# EDGE_ENABLE_BTF_CORE_DEV  — linux-renesas: btf-core-dev.cfg + pahole-native;
#                             edge-image-dev: ships bpftool. OFF by default —
#                             un-reduced DWARF + module BTF bloat the OTA bundle

# ----- Passthrough so operators can flip from the environment --------------

BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_PROFILE EDGE_OTA_BACKEND"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_ENABLE_DISPLAY EDGE_ENABLE_CONTAINERS EDGE_ENABLE_OBSERVABILITY EDGE_ACCEL"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_DEV_NETBOOT EDGE_DEV_DBG_PKGS EDGE_KERNEL_DEV_FRAGMENTS EDGE_ENABLE_JTAG_DEBUG EDGE_ENABLE_BTF_CORE_DEV"

# RAUC / OTA knobs — declared in their respective recipes (rauc-conf-edge,
# edge-bundle-common.inc, ota-certs). Passthrough so operators can flip
# them from the environment without editing kas/local.yml.
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_RAUC_STREAMING_KEY_MODE EDGE_RAUC_PKCS11_TLS_KEY"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_RAUC_KEYRING_CERTS EDGE_RAUC_ALLOWED_SIGNER_CNS EDGE_RAUC_CHECK_PURPOSE"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_ENABLE_RAUC_BUNDLE_ENCRYPTION EDGE_RAUC_ENCRYPTION_KEY EDGE_RAUC_ENCRYPTION_CERT"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS EDGE_RAUC_BUNDLE_FORMAT EDGE_RAUC_BUNDLE_FORMATS EDGE_OTA_CERT_DIR"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_RAUC_DECRYPT_KEY_SRC EDGE_RAUC_DECRYPT_CERT_SRC"
BB_ENV_PASSTHROUGH_ADDITIONS .= " EDGE_ENABLE_OPTEE EDGE_ENABLE_OPTEE_EXAMPLES"
