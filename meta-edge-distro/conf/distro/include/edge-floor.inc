# Non-negotiable distro floor.
#
# These define "edge-ai" — they are not operator-configurable. Anything
# an operator should be able to flip lives in edge-features.inc.
# Tier-specific decisions live in edge-profile-${EDGE_PROFILE}.inc.
# OTA backend wiring lives in edge-ota-${EDGE_OTA_BACKEND}.inc.

# ----- Init system --------------------------------------------------------

INIT_MANAGER                 = "systemd"
VIRTUAL-RUNTIME_init_manager = "systemd"
VIRTUAL-RUNTIME_initscripts  = "systemd-compat-units"

SYSTEMD_DEFAULT_TARGET = "multi-user.target"

# Empty the syslog virtual: packagegroup-core-boot's default pulls
# busybox-syslog.service, which duplicates journald and emits "OPTIONS
# unset" every boot. BAD_RECOMMENDATIONS guards against weak-dep pulls.
VIRTUAL-RUNTIME_base-utils-syslog = ""
BAD_RECOMMENDATIONS:append        = " busybox-syslog"

# dnsmasq excluded: nothing in the image RRECOMMENDS it, but guard against
# a future weak-dep pull. Its preset auto-enables dnsmasq.service which
# pulls network.target onto multi-user.target unnecessarily.
BAD_RECOMMENDATIONS:append        = " dnsmasq"

# ----- Network management -------------------------------------------------

# networkd owns addressing/DHCP but does NOT write /etc/resolv.conf — only
# systemd-resolved does. resolved + nss-resolve stay in systemd's default
# PACKAGECONFIG (not removed); resolved is enabled via 90-edge.preset (it has no
# recipe SYSTEMD_SERVICE, so the `disable *` preset would otherwise leave it off).
VIRTUAL-RUNTIME_net_manager = "systemd-networkd"

# /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf (resolved's
# 127.0.0.53 stub). The systemd recipe creates the symlink + tmpfiles when
# RESOLV_CONF=stub-resolv and resolved is in PACKAGECONFIG.
RESOLV_CONF = "stub-resolv"

# ----- Users / static IDs -------------------------------------------------

# Deterministic UIDs/GIDs; USERADD_ERROR_DYNAMIC = "error" makes any
# unlisted useradd/groupadd a hard parse failure — SBOM/CIS posture.
USERADDEXTENSION       = "useradd-staticids"
USERADD_UID_TABLES     = "files/passwd"
USERADD_GID_TABLES     = "files/group"
USERADD_ERROR_DYNAMIC  = "error"

# Suppress base-files' do_install_basefilesissue; prevents it from
# clobbering the edge-distro bbappend's /etc/issue{,.net} templates.
BASEFILESISSUEINSTALL = ""

# ----- Filesystem perms ---------------------------------------------------

# Drop both volatile-{log,tmp}.txt. Those tables turn /var/log and /var/tmp
# into symlinks to /var/volatile/{log,tmp} (tmpfs). /var/log stays a real
# directory so edge-persistence's var-log.mount binds /data/log over it.
# /var/tmp stays a real directory so PrivateTmp= services (systemd-logind,
# seatd, systemd-hostnamed, ...) can mount their tmpfs namespace; the
# dangling /var/volatile/tmp symlink otherwise fails them with "Not a
# directory" at exec.
FILESYSTEM_PERMS_TABLES = "files/fs-perms.txt"

# ----- Machine features ---------------------------------------------------

# meta-renesas's rzg2l-family.inc sets MACHINE_FEATURES = "opengles opencl"
# without "screen". OE-Core wrynose gates SPLASH on screen
# (image.bbclass:63): no screen, no psplash, no boot splash. Add screen
# only when the display toggle is on so headless tiers stay lean.
MACHINE_FEATURES:append = "${@bb.utils.contains('EDGE_ENABLE_DISPLAY', '1', ' screen', '', d)}"

# ----- DISTRO_FEATURES (base; toggles add to this) ------------------------

# Wrynose: BACKFILL is gone; use DEFAULTS / OPTED_OUT.
DISTRO_FEATURES_DEFAULTS  = ""
DISTRO_FEATURES_OPTED_OUT = "multiarch ptest vulkan sysvinit"

# Always-on, non-negotiable feature set. Toggle-able features
# (wayland/opengl, rauc, future swupdate) are appended below from
# EDGE_ENABLE_* / EDGE_OTA_BACKEND.
DISTRO_FEATURES = "\
    systemd \
    pam \
    pci \
    usbhost \
    ipv4 \
    ipv6 \
    vfat \
    ext2 \
    seccomp \
    security \
    selinux \
"

# Toggle-driven additions.
DISTRO_FEATURES += "${@bb.utils.contains('EDGE_ENABLE_DISPLAY', '1', 'wayland opengl', '', d)}"
DISTRO_FEATURES += "${@bb.utils.contains('EDGE_OTA_BACKEND',    'rauc', 'rauc',           '', d)}"

# ----- MAC (SELinux) ------------------------------------------------------

# MCS refpolicy variant — full module set plus the single non-hierarchical
# sensitivity dimension. The container runtime (podman/netavark/container-
# selinux) relabels with 4-field :s0 contexts; a non-MCS policy rejects those
# at lsetxattr() (EINVAL), breaking rootless bridge/host networking.
PREFERRED_PROVIDER_virtual/refpolicy = "refpolicy-mcs"

# Refpolicy ships /etc/selinux/config with SELINUX=${DEFAULT_ENFORCING}.
# Permissive is the floor: AVC denials log to audit, no domain transition
# is blocked. Flip to "enforcing" only after policy coverage has been
# validated against the full image surface. Recovery escape remains the
# selinux=0 kernel param via fw_setenv EXTRA_KERNEL_ARGS.
DEFAULT_ENFORCING = "permissive"

# ----- Packaging ----------------------------------------------------------

PACKAGE_CLASSES ?= "package_rpm"

# ----- rm_work compatibility ---------------------------------------------

# sbom-cve-check and create-spdx hook image-recipe post-do_build tasks
# (do_create_image_sbom_spdx, do_sbom_cve_check) whose sstate-outputdirs
# point at DEPLOY_DIR_IMAGE. When rm_work fires at the end of the image
# build it wipes the source side of the staging path before sstate has
# finished promoting the artefacts to deploy/images/<machine>/. The
# observable effect is missing *.spdx.json and *.sbom-cve-check.*.json
# next to the image artefacts. Excluding the image recipes preserves the
# small image WORKDIRs (no source tree, mostly rootfs assembly state
# which has its own cleandirs in image.bbclass).
RM_WORK_EXCLUDE += "edge-image-base edge-image-dev edge-image-prod"

# Empty default: a recipe that needs a license flag fails noisily, not silently.
# Capability-scoped accepts (e.g. `commercial` for the GPL/patent-encumbered
# gstreamer decoder set) live in the include that ships the capability —
# currently edge-profile-dev.inc.
LICENSE_FLAGS_ACCEPTED ?= ""

# ----- SBOM (SPDX 3.0) + CVE check ---------------------------------------

# Non-negotiable: every edge-ai build emits an SBOM and runs the CVE check.
# The sbom-cve-check fragment defaults the two CVE-DB fetch recipes to
# AUTOREV; pin back to the .bb-shipped SRCREVs so the CVE DB is part of
# the release record, not silent network-driven drift. Bump these with
# the wrynose pin in kas/base.yml.
#
# IMAGE_CLASSES:append wires sbom-cve-check.bbclass directly. The
# fragment's same line via OE_FRAGMENTS is unreliable in this wrynose
# pin — addfragments does not parse a leading-space OE_FRAGMENTS value
# (artefact of `+= " yocto/..."`). Explicit assignment here is the
# load-bearing one; OE_FRAGMENTS is left in for the fragment's other
# minor bits and as the documented hook for future operators.
INHERIT       += "create-spdx"
OE_FRAGMENTS  += "yocto/sbom-cve-check"
IMAGE_CLASSES:append = " sbom-cve-check"
# nvd-json-data-feeds @ 2026-06-16
SRCREV:pn-sbom-cve-check-update-nvd-native     = "b9056dbe8175514b36ed1720cd223fc73aa1796c"
# cvelistV5 @ 2026-06-16
SRCREV:pn-sbom-cve-check-update-cvelist-native = "d34c26123e45e877be017cf361b64edc0eefc4b6"

# sbom-cve-check fragment hard-codes the SPDX compiled-sources flag for
# linux-yocto; apply to linux-renesas so kernel CVE
# source-attribution doesn't over-report.
SPDX_INCLUDE_COMPILED_SOURCES:pn-linux-renesas = "1"

# The default ("current") drops fixed-version and cpe-stable-backport
# CVE_STATUS entries from the VEX export on the assumption the CVE DB's
# version range clears those rows itself. When the range data is wrong
# (NVD ranges lag point releases; git-hash recipes never version-match),
# the disposition is silently lost and the row ships Unpatched — observed
# on rsync, ffmpeg (15 rows), and glibc (3 rows). "all" exports every
# exportable disposition (unknown is skipped), so the report reflects
# recipe CVE_STATUS verbatim.
SPDX_INCLUDE_VEX = "all"

# ----- FIT verified boot (file-key dev profile) --------------------------

# Non-negotiable: signed FIT is the boot path. The profile (file-key vs
# HSM) can change; the fact of signing cannot. mkimage auto-generates
# the key pair into UBOOT_SIGN_KEYDIR on first build; keys/dev/fit/ is
# gitignored.
UBOOT_SIGN_ENABLE      ?= "1"
UBOOT_SIGN_KEYDIR      ?= "${TOPDIR}/../keys/dev/fit"
UBOOT_SIGN_KEYNAME     ?= "edge-fit-dev"
FIT_HASH_ALG           ?= "sha256"
FIT_SIGN_ALG           ?= "rsa2048"
FIT_GENERATE_KEYS      ?= "1"
FIT_SIGN_INDIVIDUAL    ?= "0"

# ----- RAUC bundle signing (file-key dev profile) -------------------------

# Chain-rooted PKI: leaf (with codeSigning EKU) signs the bundle; root CA
# is installed on the device as /etc/rauc/ca.cert.pem. Generate the chain
# with scripts/rauc-init-certs.sh — keys live under keys/dev/rauc/, same
# pattern as keys/dev/fit/ for the FIT signing. keys/ is gitignored.
#
# RAUC_DEVICE_KEYRING is a project-local variable consumed by rauc-conf-edge;
# explicitly pin to the CA so the leaf is NOT installed on the device
# (only the CA needs to be there for chain verification).
RAUC_KEY_FILE       ?= "${TOPDIR}/../keys/dev/rauc/rauc-signer.key"
RAUC_CERT_FILE      ?= "${TOPDIR}/../keys/dev/rauc/rauc-signer.cert.pem"
RAUC_KEYRING_FILE   ?= "${TOPDIR}/../keys/dev/rauc/rauc-ca.cert.pem"
RAUC_DEVICE_KEYRING ?= "${RAUC_KEYRING_FILE}"

# ----- RAUC bundle encryption (crypt format, opt-in) ----------------------

# Recipient PKI, independent of the signing PKI above: `rauc encrypt`
# CMS-envelopes the manifest to the certs in the recipients PEM, and the
# device decrypts with the matching private key. rauc-init-certs.sh emits all
# three files; an empty *_SRC pair leaves the device key to a PKCS#11 token.
#
# Consumed by: edge-bundle-common.inc (recipients), ota-certs (device key
# and cert), rauc-conf-edge (the [encryption] stanza that names them).
EDGE_RAUC_BUNDLE_ENCRYPT_RECIPIENTS ?= "${TOPDIR}/../keys/dev/rauc/rauc-recipients.pem"
EDGE_RAUC_DECRYPT_KEY_SRC           ?= "${TOPDIR}/../keys/dev/rauc/rauc-recipient.key"
EDGE_RAUC_DECRYPT_CERT_SRC          ?= "${TOPDIR}/../keys/dev/rauc/rauc-recipient.cert.pem"

# ----- Build identifier ---------------------------------------------------

# NOT SOURCE_DATE_EPOCH: oe-core hard-pins that to 1302044400 (2011-04-05)
# for rootfs-mtime determinism — wiring it here makes the banner read
# "Built: 2011" forever. Use wall-clock DATETIME; banner display only.
EDGE_BUILD_ID    ?= "${DATETIME}"
EDGE_BUILD_ID[vardepsexclude] = "DATETIME"

# Pre-slice at parse time; recipe shell (/bin/sh) lacks ${VAR:off:len}.
EDGE_BUILD_DATE  ?= "${@(lambda v: v[:4] + '-' + v[4:6] + '-' + v[6:8] if len(v) >= 8 else 'unknown')(d.getVar('EDGE_BUILD_ID') or '')}"
EDGE_BUILD_DATE[vardepsexclude] = "DATETIME EDGE_BUILD_ID"

# ----- Fetcher policy ----------------------------------------------------

# crates.io now returns 403 to wget's default "Wget/1.x" User-Agent and
# 302s to static.crates.io for browser UAs. Override the default fetcher
# command so https:// fetches present a real UA. The wget fetcher reads
# the literal name `FETCHCMD_wget` (bb/fetch2/wget.py:86) — "wget" is not
# in OVERRIDES, so `FETCHCMD:wget` doesn't reach it via override mapping.
# We set the underscore form for the fetcher and mirror it as colon-form
# for visibility in `bitbake -e`. Affects every wget pull but only
# crates.io currently filters on UA.
FETCHCMD_wget = "/usr/bin/env wget --tries=2 --timeout=100 --user-agent=Mozilla/5.0"
FETCHCMD:wget = "${FETCHCMD_wget}"

# ----- Misc ---------------------------------------------------------------

SDK_NAME_PREFIX ?= "edge"

# Hash-equivalence DB next to the shared SSTATE_DIR. Silences the
# "hashserv DB is inside build dir but sstate is shared" warning.
BB_HASHSERVE_DB_DIR ?= "${SSTATE_DIR}/hashserv"

# defaultsetup.conf auto-pulls default-distrovars/maintainers/security_flags
# once DISTRO is set — don't re-require, triggers "Duplicate inclusion".
