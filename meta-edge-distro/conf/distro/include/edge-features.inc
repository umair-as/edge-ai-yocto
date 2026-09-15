# Operator-facing toggles for the edge-ai distro.
#
# All declared with ?= so kas/local.yml wins. A shell environment override
# does NOT win unless the variable is on the Makefile's shell-level
# BB_ENV_PASSTHROUGH_ADDITIONS list -- bitbake discards the rest of the
# environment before this file is parsed. See the note further down.

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
# netns support is already on via kernel fragments; the userspace runtime and
# its principal are unconditional base OS content on every machine and every
# tier -- there is no toggle, deliberately. See ADR-0012.

# Accelerator selection. Single-valued on purpose: one populated accelerator
# per image is what the platform builds, and widening a single value to a list
# later is a smaller change than un-picking a list nobody validated.
#
#   EDGE_ACCEL            what this image is built for; set by kas/accel/<name>.yml
#   EDGE_ACCEL_SUPPORTED  what THIS machine can carry; set by the board include
#
# The pair is checked in edge-image.bbclass: an unsupported combination is a
# parse error naming both values, never a quietly accelerator-less image.
# No distro-scope default. edge-features.inc is required at edge-ai.conf:25
# and the board include lands at :42, so a `?=` here would claim the slot and
# silently defeat the board's own default. EDGE_ACCEL is set by the machine's
# accelerator fragment (kas/accel/<name>.yml, composed from the machine
# fragment). Unset means no accelerator was composed, which edge-image.bbclass
# treats as a build error rather than a fallback.
EDGE_ACCEL_SUPPORTED ??= ""

# Supplementary groups the accelerator's runtime principal needs. Applied at
# image assembly by edge-users.inc, not by a recipe useradd: the groups are
# created by other recipes and a recipe-level --groups races their creation.
EDGE_ACCEL_SUPPLEMENTARY_GROUPS ??= ""

# Accelerator-supplied test/measurement packages for dev images. Set by the
# accelerator fragment, not by an image or a machine override -- the
# accelerator owns its own test content, and a generic image recipe must not
# name a board to find it.
EDGE_ACCEL_TEST_INSTALL ??= ""

# Board-fact declarations in this file use ??=, never ?=. This file is
# required at edge-ai.conf:25 and the board include lands at :42, so a ?=
# empty default here claims the slot first and the board's own ?= becomes a
# no-op -- the variable reads empty and the fail-closed check fires on a
# board that did set it. ??= is applied only if nothing else ever assigns.
#
# Boot-chain family. Five recipes assume TF-A/OP-TEE -> U-Boot -> signed FIT
# verified against a key in U-Boot's control DTB -> raw U-Boot env for RAUC's
# boot-count. Declared so that assumption is a parse-time fact rather than
# five silent ones. Set by the board include; the implemented set is
# {"uboot-fit"} and edge-image.bbclass refuses anything else.
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
# here, fdt_add_pubkey into the board DTB elsewhere).
EDGE_FIT_PUBKEY_DTB ??= ""

# EDGE_ENABLE_AI is retired. It was a derived read-only alias for
# "is an accelerator selected", which is now always true: every board this
# distro targets carries one, and edge-image.bbclass refuses to build without
# it. A variable that cannot be 0 is not a toggle. Use EDGE_ACCEL to name
# which accelerator; it is never "none" outside an EDGE_ALLOW_NO_ACCEL
# bring-up composition.

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

# ----- Why there is no BB_ENV_PASSTHROUGH_ADDITIONS block here -------------
#
# There used to be one, listing ~25 EDGE_* variables so "operators could flip
# them from the environment". It never worked. bitbake filters the inherited
# environment at startup and reads BB_ENV_PASSTHROUGH_ADDITIONS *from the
# environment* to decide what survives; a conf file is parsed long after that
# decision, so appending here names variables that were already discarded.
# Measured: `EDGE_ENABLE_OBSERVABILITY=0 bitbake-getvar ...` still resolves 1.
#
# The passthrough that does work is established before bitbake starts -- the
# Makefile sets BB_ENV_PASSTHROUGH_ADDITIONS in the shell it invokes bitbake
# from. Anything that must be settable from the environment goes on that list
# in the Makefile; everything else is a make flag mapped to a kas fragment.
# This matches AGENTS.md §"Build commands", which already states that a bare
# EDGE_*=1 exported in the shell is silently dropped.
#
# Keeping the dead block was worse than having none: it advertised a control
# surface that silently did nothing.
