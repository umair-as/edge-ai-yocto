# Operator-facing toggles for the edge-ai distro.
#
# All declared with ?= so kas/local.yml wins. A shell environment override
# does NOT win unless the variable is on the Makefile's shell-level
# BB_ENV_PASSTHROUGH_ADDITIONS list -- bitbake discards the rest of the
# environment before this file is parsed.

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

# Container userspace is unconditional base OS content on every tier and
# machine, with no toggle (ADR-0012): the accelerator runtimes ship Quadlet
# units.

# Accelerator selection, single-valued: one accelerator per image.
#
#   EDGE_ACCEL            what this image is built for; set by kas/accel/<name>.yml
#   EDGE_ACCEL_SUPPORTED  what this machine can carry; set by the board include
#
# edge-image.bbclass checks the pair at parse. EDGE_ACCEL has no distro
# default; unset is a build error there.
EDGE_ACCEL_SUPPORTED ??= ""

# Supplementary groups the accelerator's runtime principal needs. Applied at
# image assembly by edge-users.inc, not by a recipe useradd: the groups are
# created by other recipes and a recipe-level --groups races their creation.
EDGE_ACCEL_SUPPLEMENTARY_GROUPS ??= ""

# Accelerator-supplied test/measurement packages for dev images, set by the
# accelerator fragment so image recipes stay board-neutral.
EDGE_ACCEL_TEST_INSTALL ??= ""

# Board-fact declarations use ??=, never ?=: this file is required before
# the board include (edge-ai.conf), so a ?= default here would turn the
# board's own ?= into a no-op.
#
# Boot-chain family: firmware -> U-Boot -> signed FIT verified against a key
# in U-Boot's control DTB -> raw U-Boot env for RAUC's boot-count. Only
# "uboot-fit" is implemented; edge-image.bbclass refuses anything else.
EDGE_BOOT_CHAIN ??= ""

# Network interface roles. Board facts: which interfaces systemd-networkd must
# leave alone (a netboot board reserves its NFS-root interface for the
# kernel's ip=dhcp path), and which carries the DHCP uplink. Empty
# EDGE_UNMANAGED_IFACES is valid; an empty uplink is not.
EDGE_UNMANAGED_IFACES ??= ""
EDGE_UPLINK_IFACE ??= ""

# Boot and data partitions, as device paths. Needed only where the partition
# layout carries no identity (MBR/eSD): a GPT board finds them by PARTLABEL
# and leaves these empty. The A/B slot devices are EDGE_SLOT_A/B_DEVICE.
EDGE_BOOT_DEVICE ??= ""
EDGE_DATA_DEVICE ??= ""

# Partition table of the boot medium: "msdos" or "gpt". Decides where slot
# identity comes from -- device names on MBR, which carries no partition
# names, or GPT partition names. Set by the board include.
EDGE_PTABLE ??= ""

# Raw U-Boot environment area, where RAUC keeps its boot-count. Board facts:
# the block device and the two redundant offsets/size. They must agree with
# CONFIG_ENV_OFFSET / CONFIG_ENV_OFFSET_REDUND / CONFIG_ENV_SIZE in the
# board's U-Boot, or RAUC's state silently never persists.
EDGE_UBOOT_ENV_DEVICE ??= ""
EDGE_UBOOT_ENV_OFFSET ??= ""
EDGE_UBOOT_ENV_OFFSET_REDUND ??= ""
EDGE_UBOOT_ENV_SIZE ??= ""

# The deployed DTB that is U-Boot's control FDT at runtime -- the file whose
# /signature node is the FIT trust anchor. Board fact because how the key
# reaches the control FDT differs per board (concatenated signed U-Boot DTB
# on RZ/V2L, fdt_add_pubkey into the board DTB on RPi5).
EDGE_FIT_PUBKEY_DTB ??= ""

# No EDGE_ENABLE_AI: an accelerator is always selected. EDGE_ACCEL names it,
# and is "none" only in an EDGE_ALLOW_NO_ACCEL bring-up composition.

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

# No BB_ENV_PASSTHROUGH_ADDITIONS here: bitbake reads it from the environment
# at startup, before any conf file is parsed, so an append in conf has no
# effect. The Makefile sets it in the shell that runs bitbake.
